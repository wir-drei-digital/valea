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

const BACKEND_PORT: u16 = 4817;

/// Holds the sidecar process so it can be killed on exit.
struct Backend(Mutex<Option<CommandChild>>);

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
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(Backend(Mutex::new(None)))
        .invoke_handler(tauri::generate_handler![
            keychain::mail_secret_set,
            keychain::mail_secret_get,
            keychain::mail_secret_delete
        ])
        .setup(|app| {
            if cfg!(debug_assertions) {
                // Dev: the backend runs via `just dev-desktop` / `mix phx.server`
                // and the frontend talks to it through the Vite proxy, taking its
                // token from VITE_VALEA_CONTROL_TOKEN. We still inject the fixed
                // dev token (matching config/runtime.exs) so the window works even
                // if it ever loads a non-proxied origin.
                build_main_window(app.handle(), "valea-dev-token")?;
            } else {
                start_sidecar(app.handle())?;
            }
            Ok(())
        })
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
    let data_dir = app.path().app_data_dir()?;
    std::fs::create_dir_all(&data_dir)?;

    let secret = read_or_create_secret(&data_dir.join("secret_key_base"))?;

    // Fresh per launch: the control token gates every RPC/socket connection,
    // the readiness nonce proves the server answering on 4817 is really ours.
    let token = random_hex();
    let nonce = random_hex();

    let (_rx, child) = app
        .shell()
        .sidecar("valea-server")?
        .env("PHX_SERVER", "true")
        .env("PORT", BACKEND_PORT.to_string())
        .env("PHX_HOST", "localhost")
        .env("SECRET_KEY_BASE", secret)
        .env("VALEA_CONTROL_TOKEN", &token)
        .env("VALEA_READY_NONCE", &nonce)
        .spawn()?;

    app.state::<Backend>().0.lock().unwrap().replace(child);

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

    let window = WebviewWindowBuilder::from_config(app, &config)?
        .initialization_script(script)
        .on_navigation(|url| {
            // Pin the webview to the loopback origin so the init-script token
            // can never reach a remote page. Allow only the backend origin
            // (4817) and the Vite dev origin (4273); non-http(s) schemes
            // (tauri:, about:, blob:, data:) are webview internals, left alone.
            match url.scheme() {
                "http" | "https" => {
                    matches!(url.host_str(), Some("localhost") | Some("127.0.0.1"))
                        && matches!(url.port(), Some(4817) | Some(4273))
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
