// keychain.rs — service = bundle identifier; account = "<workspace_id>:<username>".
// Never log the secret. Errors map to a short string for the frontend.
use keyring::Entry;

const SERVICE: &str = "digital.wirdrei.valea";

fn entry(workspace_id: &str, username: &str) -> Result<Entry, String> {
    if workspace_id.is_empty() || username.is_empty() {
        return Err("bad key".into());
    }
    Entry::new(SERVICE, &format!("{workspace_id}:{username}")).map_err(|e| e.to_string())
}

#[tauri::command]
pub fn mail_secret_set(
    workspace_id: String,
    username: String,
    secret: String,
) -> Result<(), String> {
    entry(&workspace_id, &username)?
        .set_password(&secret)
        .map_err(|e| e.to_string())
}

#[tauri::command]
pub fn mail_secret_get(workspace_id: String, username: String) -> Result<Option<String>, String> {
    match entry(&workspace_id, &username)?.get_password() {
        Ok(s) => Ok(Some(s)),
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(e.to_string()),
    }
}

#[tauri::command]
pub fn mail_secret_delete(workspace_id: String, username: String) -> Result<(), String> {
    match entry(&workspace_id, &username)?.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(e.to_string()),
    }
}
