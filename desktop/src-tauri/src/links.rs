// links.rs — open an external http(s) URL in the OS default browser.
// The Tauri webview installs no window factory, so the SPA's `window.open`
// silently does nothing in desktop mode; external links route through this
// command instead. http/https ONLY — never file paths, custom schemes, or
// programs — so the shell plugin's opener can't be aimed at anything but
// the user's browser. Errors map to a short string for the frontend, same
// convention as keychain.rs.
//
// `open_url` is the same door for callers already inside Rust: `main.rs`'s
// navigation guard hands it every off-loopback http(s) navigation the
// webview tries to make, so a link the SPA did NOT intercept still reaches
// the browser rather than being silently cancelled.
use tauri_plugin_shell::ShellExt;

pub fn open_url(app: &tauri::AppHandle, url: &str) -> Result<(), String> {
    let lower = url.to_ascii_lowercase();
    if !(lower.starts_with("https://") || lower.starts_with("http://")) {
        return Err("unsupported url scheme".into());
    }
    app.shell().open(url, None).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn open_external(app: tauri::AppHandle, url: String) -> Result<(), String> {
    open_url(&app, &url)
}
