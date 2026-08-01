// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::io::{Read, Write};
use std::net::{SocketAddr, TcpStream};
use std::sync::Mutex;
use std::time::Duration;
use tauri::{Manager, WebviewWindowBuilder};
use tauri_plugin_dialog::{DialogExt, MessageDialogKind};
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

mod keychain;
mod links;
mod winjob;

const BACKEND_PORT: u16 = 4817;

/// Suffix marking a locally built bundle (`digital.wirdrei.valea.dev`, from
/// `tauri.dev.conf.json` via `just desktop-bundle`). A local build and an
/// installed release are otherwise the same app to macOS AND to Burrito; this
/// is the one bit that tells them apart at runtime.
const DEV_IDENTIFIER_SUFFIX: &str = ".dev";

/// Holds the sidecar process so it can be killed on exit.
struct Backend(Mutex<Option<CommandChild>>);

/// Owns the sidecar's kill-on-close Job handle for the app's lifetime
/// (windows-support spec E1). Never read back — its existence IS the
/// semantics: whenever this process goes away, so does the Job handle, and
/// with it the whole BEAM tree that `Backend`'s `kill()` cannot reach.
#[cfg(windows)]
struct SidecarJob(Mutex<Option<winjob::Job>>);

/// Outcome of the sidecar readiness probe.
enum Readiness {
    /// The sidecar answered `/api/health` with the nonce we generated.
    Ready,
    /// Something answered on the port, but not with our nonce — another
    /// process owns 4817. Loading the SPA against it would leak the control
    /// token to a stranger's server, so we refuse.
    PortCollision,
    /// Nothing ever answered within the timeout.
    Timeout,
}

fn main() {
    // issue #1 (bug 3): on KDE Plasma Wayland, WebKitGTK's dmabuf renderer
    // aborts the app before any window appears ("Error 71 (Protocol error)
    // dispatching to Wayland display"). Disabling that one renderer path is
    // the reporter-verified clean fix (native Wayland kept, empty journal),
    // vs. GDK_BACKEND=x11 which works but spams GBM buffer errors. Gated to
    // Wayland sessions, and only as a default — a user who sets the variable
    // themselves (even to empty/0 to force dmabuf back on) wins. Must run
    // before the builder below initialises GTK.
    #[cfg(target_os = "linux")]
    {
        let wayland = std::env::var_os("WAYLAND_DISPLAY").is_some()
            || std::env::var("XDG_SESSION_TYPE").is_ok_and(|v| v == "wayland");
        if wayland && std::env::var_os("WEBKIT_DISABLE_DMABUF_RENDERER").is_none() {
            std::env::set_var("WEBKIT_DISABLE_DMABUF_RENDERER", "1");
        }
    }

    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        // Auto-update: the SPA (stores/updates.svelte.ts) drives check/
        // download/install through these two plugins; `updater` verifies the
        // minisign signature against the pubkey in tauri.conf.json, `process`
        // provides the relaunch. Sidecar cleanup on relaunch needs no extra
        // wiring — restart goes through the normal exit path, so the
        // RunEvent::Exit handler below kills the old sidecar before the new
        // process boots its own.
        .plugin(tauri_plugin_updater::Builder::new().build())
        .plugin(tauri_plugin_process::init())
        // New-mail notifications (mail full-client plan, M5 task 13): the SPA
        // (src/lib/notify.ts) asks for permission lazily, the first time a
        // user turns the per-account toggle on, and posts one notification per
        // sync pass that landed unread INBOX mail. Nothing here decides WHEN —
        // the plugin only provides the OS surface, gated by
        // capabilities/notifications.json.
        .plugin(tauri_plugin_notification::init())
        .manage(Backend(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            keychain::mail_secret_set,
            keychain::mail_secret_get,
            keychain::mail_secret_delete,
            links::open_external
        ])
        .setup(|app| {
            if cfg!(debug_assertions) {
                // Dev: the backend runs via `just dev-desktop` / `mix phx.server`
                // and the frontend talks to it through the Vite proxy, taking its
                // token from VITE_VALEA_CONTROL_TOKEN. We still inject the fixed
                // dev token (matching config/runtime.exs) so the window works even
                // if it ever loads a non-proxied origin.
                build_main_window(app.handle(), "valea-dev-token")?;
            } else if let Err(e) = start_sidecar(app.handle()) {
                // issue #1: propagating this through `?` panics tauri's run()
                // with a bare status=101 and no user-visible text — the 0744
                // sidecar bug surfaced exactly that way. Fail like the timeout/
                // port-collision paths instead: a readable dialog, then exit.
                eprintln!("failed to start sidecar: {e}");
                app.dialog()
                    .message(format!(
                        "Valea could not start its backend: {e}"
                    ))
                    .kind(MessageDialogKind::Error)
                    .title("Valea can't start")
                    .blocking_show();
                std::process::exit(1);
            }
            Ok(())
        });

    // windows-support spec E1: the sidecar's Job handle needs an owner that
    // outlives `start_sidecar` — dropping it would close the Job and kill the
    // sidecar on the spot. See `SidecarJob`.
    #[cfg(windows)]
    let builder = builder.manage(SidecarJob(Mutex::new(None)));

    builder
        .build(tauri::generate_context!())
        .expect("error while building tauri application")
        .run(|app, event| {
            if matches!(event, tauri::RunEvent::Exit) {
                if let Some(child) = app.state::<Backend>().0.lock().unwrap().take() {
                    let _ = child.kill();
                }
            }
        });
}

fn start_sidecar(app: &tauri::AppHandle) -> Result<(), Box<dyn std::error::Error>> {
    // windows-support spec A6: LOCAL app data, never Roaming — identical
    // paths on macOS/Linux, %LOCALAPPDATA% instead of %APPDATA% on Windows.
    let data_dir = app.path().app_local_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;

    let secret = read_or_create_secret(&data_dir.join("secret_key_base"))?;

    // Fresh per launch: the control token gates every RPC/socket connection,
    // the readiness nonce proves the server answering on 4817 is really ours.
    let token = random_hex();
    let nonce = random_hex();

    // windows-support spec B2: agents are spawned through the valea-spawn
    // shim, which Tauri bundles next to the app executable (externalBin strips
    // the target triple from the copied name). Handing the backend an absolute
    // path keeps PATH lookup out of it. Absent — an unbundled run — means the
    // env var is simply not set, and the backend's doctor reports the gap.
    #[cfg(windows)]
    let spawn_shim = std::env::current_exe()?
        .parent()
        .map(|d| d.join("valea-spawn.exe"))
        .filter(|p| p.exists());

    let cmd = app
        .shell()
        .sidecar("valea-server")?
        // REQUIRED, not cosmetic (issue #1, bug 2). The sidecar is a
        // Burrito-wrapped release: burrito's launcher (erlang_launcher.zig)
        // builds `erl ... -s elixir start_cli ... -extra` and appends OUR
        // argv after `-extra`, so these args go to `elixir start_cli` — and
        // burrito never supplies `--no-halt` itself. Without it, start_cli
        // boots the app (endpoint bound, logs emitted) and then halts the VM
        // with status 0 about a second later; the port dies with it,
        // await_readiness() never sees a healthy response, and the user gets
        // the "backend did not start in time" dialog instead of a window.
        // Debug builds take the `mix phx.server` branch in setup() and never
        // spawn this, so no dev run exercises it. Verified against the real
        // staged sidecar on macOS: argless → exit 0 after ~1s; --no-halt →
        // stays up, /api/health returns the launch nonce.
        .args(["--no-halt"])
        .env("PHX_SERVER", "true")
        .env("PORT", BACKEND_PORT.to_string())
        .env("PHX_HOST", "localhost")
        .env("SECRET_KEY_BASE", secret)
        .env("VALEA_CONTROL_TOKEN", &token)
        .env("VALEA_READY_NONCE", &nonce);

    // Burrito unpacks the sidecar to <base>/valea_desktop_erts-<erts>_<version>
    // and skips extraction whenever that directory already exists — the check
    // is bare existence, no payload hash (deps/burrito/src/wrapper.zig, "If the
    // metadata file exists, don't install again"). The key contains the mix.exs
    // version but NOT the bundle identifier, so a locally built bundle and an
    // installed release at the same version share one unpacked backend:
    // whichever launches first extracts, the other silently runs code it was
    // not built with. Renaming the dev bundle alone does not fix that.
    //
    // So dev bundles get their own base dir. `data_dir` is already
    // identifier-scoped (…/digital.wirdrei.valea.dev/), which makes this
    // separation automatic rather than another string to keep in sync.
    // Release builds are deliberately left on Burrito's default so their
    // payload path stays exactly what shipped installs already use.
    let cmd = if app.config().identifier.ends_with(DEV_IDENTIFIER_SUFFIX) {
        cmd.env("VALEA_DESKTOP_INSTALL_DIR", data_dir.join("burrito"))
    } else {
        cmd
    };

    #[cfg(windows)]
    let cmd = match &spawn_shim {
        Some(shim) => cmd.env("VALEA_SPAWN_SHIM", shim),
        None => cmd,
    };

    let (mut rx, child) = cmd.spawn()?;

    // Registered FIRST, before anything else that can fail: a spawned sidecar
    // that is not in `Backend` is one RunEvent::Exit will never kill, i.e. a
    // BEAM left running after the app window closes.
    #[cfg(windows)]
    let pid = child.pid();
    app.state::<Backend>().0.lock().unwrap().replace(child);

    // issue #1: the receiver used to be dropped (`_rx`), so the sidecar's
    // output reached neither the journal nor a terminal — diagnosing the
    // boot-then-halt bug required shimming beam.smp just to see anything.
    // Forward everything to OUR stderr, where the OS log (journald /
    // Console.app) already collects it.
    tauri::async_runtime::spawn(async move {
        use tauri_plugin_shell::process::CommandEvent;
        while let Some(event) = rx.recv().await {
            match event {
                CommandEvent::Stdout(line) | CommandEvent::Stderr(line) => {
                    eprintln!("[valea-server] {}", String::from_utf8_lossy(&line));
                }
                CommandEvent::Error(e) => eprintln!("[valea-server] io error: {e}"),
                CommandEvent::Terminated(status) => {
                    eprintln!(
                        "[valea-server] exited: code={:?} signal={:?}",
                        status.code, status.signal
                    );
                }
                _ => {}
            }
        }
    });

    // windows-support spec E1: the Burrito wrapper can't exec() on Windows, so
    // the `child.kill()` in main()'s RunEvent::Exit handler would orphan the
    // BEAM. Put the sidecar in a kill-on-close Job and park the handle in
    // managed state for the app's lifetime. Nothing drops that handle — tao's
    // event loop diverges through `process::exit`, so `Job::drop` never runs;
    // the reap happens because process teardown closes the handle table, which
    // is what fires KILL_ON_JOB_CLOSE. That also covers a crash or a force-quit,
    // where `kill()` never gets a chance.
    #[cfg(windows)]
    match winjob::Job::assign_kill_on_close(pid) {
        Ok(job) => {
            app.state::<SidecarJob>().0.lock().unwrap().replace(job);
        }
        Err(e) => {
            // Without the Job there is no guarantee the tree dies with the app,
            // so refuse to run half-managed: take the sidecar back out and kill
            // what we just started before failing setup.
            if let Some(child) = app.state::<Backend>().0.lock().unwrap().take() {
                let _ = child.kill();
            }
            return Err(e.into());
        }
    }

    // Probe readiness off the main thread, then either build the window (with
    // the token init script) or show a fatal dialog — both on the main thread.
    let handle = app.clone();
    std::thread::spawn(move || {
        let outcome = await_readiness(&nonce);

        match outcome {
            Readiness::Ready => {
                let h = handle.clone();
                let token = token.clone();
                let _ = handle.run_on_main_thread(move || {
                    if let Err(e) = build_main_window(&h, &token) {
                        eprintln!("failed to create main window: {e}");
                    }
                });
            }
            Readiness::PortCollision | Readiness::Timeout => {
                let message = match outcome {
                    Readiness::PortCollision => format!(
                        "Another program is already using port {BACKEND_PORT}. \
                         Quit it and open Valea again."
                    ),
                    _ => "Valea's backend did not start in time. Please try again.".to_string(),
                };
                let h = handle.clone();
                let _ = handle.run_on_main_thread(move || {
                    h.dialog()
                        .message(message)
                        .kind(MessageDialogKind::Error)
                        .title("Valea can't start")
                        .blocking_show();
                    h.exit(1);
                });
            }
        }
    });

    Ok(())
}

/// Polls `/api/health` (max ~20s) until the sidecar answers with our nonce.
fn await_readiness(expected_nonce: &str) -> Readiness {
    for _ in 0..100 {
        match fetch_health_body(BACKEND_PORT) {
            // Not up yet — connection refused / no response. Keep waiting.
            None => std::thread::sleep(Duration::from_millis(200)),
            // Someone answered. Only our sidecar knows the nonce.
            Some(body) => {
                return match parse_nonce(&body) {
                    Some(n) if n == expected_nonce => Readiness::Ready,
                    _ => Readiness::PortCollision,
                };
            }
        }
    }
    Readiness::Timeout
}

/// Minimal loopback HTTP GET of `/api/health`. Returns the response body, or
/// `None` if the connection failed (server not up yet). Avoids pulling in a
/// full HTTP client for one same-origin probe.
fn fetch_health_body(port: u16) -> Option<String> {
    let addr = SocketAddr::from(([127, 0, 0, 1], port));
    let mut stream = TcpStream::connect_timeout(&addr, Duration::from_millis(300)).ok()?;
    stream.set_read_timeout(Some(Duration::from_secs(2))).ok()?;
    stream
        .write_all(b"GET /api/health HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        .ok()?;

    let mut raw = String::new();
    stream.read_to_string(&mut raw).ok()?;

    // Body follows the blank line separating headers from content.
    raw.split("\r\n\r\n").nth(1).map(str::to_string)
}

fn parse_nonce(body: &str) -> Option<String> {
    let value: serde_json::Value = serde_json::from_str(body.trim()).ok()?;
    value.get("nonce")?.as_str().map(str::to_string)
}

/// Builds the main window from its (create:false) config entry, injecting the
/// control token before any page script runs.
///
/// SECURITY: a Tauri v2 initialization script runs on EVERY page load in this
/// webview — including a remote origin, if the SPA were ever navigated off
/// loopback. It is NOT "invisible to cross-origin pages". The token is safe
/// today only because this window is pinned to the loopback origin: the SPA is
/// served from `http://localhost:4817` (or the Vite dev origin), its CSP and
/// the absence of external links keep it there, and the `on_navigation` guard
/// below refuses any http(s) navigation off loopback as defence in depth.
fn build_main_window(app: &tauri::AppHandle, token: &str) -> tauri::Result<()> {
    let config = app
        .config()
        .app
        .windows
        .iter()
        .find(|w| w.label == "main")
        .cloned()
        .expect("main window must be defined in tauri.conf.json");

    let script = format!("window.__VALEA_CONTROL_TOKEN = \"{token}\";");

    let nav_app = app.clone();
    let window = WebviewWindowBuilder::from_config(app, &config)?
        .initialization_script(script)
        .on_navigation(move |url| {
            // Pin the webview to the loopback origin so the init-script token
            // can never reach a remote page. Allow only the backend origin
            // (4817) and the Vite dev origin (4273); non-http(s) schemes
            // (tauri:, about:, blob:, data:) are webview internals, left alone.
            match url.scheme() {
                "http" | "https" => {
                    let loopback = matches!(url.host_str(), Some("localhost") | Some("127.0.0.1"))
                        && matches!(url.port(), Some(4817) | Some(4273));
                    if !loopback {
                        // Off-loopback means a link that leaves the app, so
                        // send it where it belongs — the user's browser —
                        // instead of only refusing it. This handler is the
                        // LAST line for a click the SPA didn't already route
                        // through `open_external`, and it fires for SUBFRAME
                        // navigations too (wry hands every WKNavigationAction
                        // here, main frame or not). That is what an HTML mail
                        // body's links depend on: the frontend intercepts them
                        // by reaching into the sandboxed iframe, which works
                        // in Chromium and not in this webview — so without
                        // this, clicking a link in a mail did nothing at all.
                        // The navigation itself stays cancelled either way.
                        let _ = links::open_url(&nav_app, url.as_str());
                    }
                    loopback
                }
                _ => true,
            }
        })
        .build()?;

    let _ = window.show();
    Ok(())
}

/// 32 random bytes as lowercase hex.
fn random_hex() -> String {
    use rand::RngCore;

    let mut bytes = [0u8; 32];
    rand::rng().fill_bytes(&mut bytes);
    bytes.iter().map(|b| format!("{b:02x}")).collect()
}

/// The desktop app owns its own SECRET_KEY_BASE: generated once per install,
/// persisted in the app data dir.
fn read_or_create_secret(path: &std::path::Path) -> std::io::Result<String> {
    use rand::distr::{Alphanumeric, SampleString};

    if path.exists() {
        std::fs::read_to_string(path)
    } else {
        let secret = Alphanumeric.sample_string(&mut rand::rng(), 64);
        std::fs::write(path, &secret)?;
        Ok(secret)
    }
}
