// Prevents an extra console window on Windows in release builds.
#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

use std::net::TcpStream;
use std::sync::Mutex;
use std::time::Duration;
use tauri::Manager;
use tauri_plugin_shell::process::CommandChild;
use tauri_plugin_shell::ShellExt;

const BACKEND_PORT: u16 = 4817;

/// Holds the sidecar process so it can be killed on exit.
struct Backend(Mutex<Option<CommandChild>>);

fn main() {
    tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_dialog::init())
        .manage(Backend(Mutex::new(None)))
        .setup(|app| {
            if cfg!(debug_assertions) {
                // Dev: the backend runs via `just dev-desktop` / `mix phx.server`,
                // and the frontend talks to it through the Vite proxy.
                if let Some(window) = app.get_webview_window("main") {
                    let _ = window.show();
                }
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

    let (_rx, child) = app
        .shell()
        .sidecar("valea-server")?
        .env("PHX_SERVER", "true")
        .env("PORT", BACKEND_PORT.to_string())
        .env("PHX_HOST", "localhost")
        .env("SECRET_KEY_BASE", secret)
        .spawn()?;

    app.state::<Backend>().0.lock().unwrap().replace(child);

    // Show the window once the backend accepts connections (max ~20s).
    let handle = app.clone();
    std::thread::spawn(move || {
        let addr = std::net::SocketAddr::from(([127, 0, 0, 1], BACKEND_PORT));
        for _ in 0..100 {
            if TcpStream::connect_timeout(&addr, Duration::from_millis(200)).is_ok() {
                break;
            }
            std::thread::sleep(Duration::from_millis(200));
        }
        if let Some(window) = handle.get_webview_window("main") {
            let _ = window.show();
        }
    });

    Ok(())
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
