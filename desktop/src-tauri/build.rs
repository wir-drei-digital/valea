fn main() {
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&[
            "mail_secret_set",
            "mail_secret_get",
            "mail_secret_delete",
        ]),
    ))
    .expect("failed to run tauri-build")
}
