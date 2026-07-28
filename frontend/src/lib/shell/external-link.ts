// Opens an http(s) URL in the user's ACTUAL browser. In the Tauri desktop
// the webview installs no window factory, so `window.open` silently does
// nothing — external links route through the desktop crate's
// `open_external` command (src-tauri/src/links.rs, http/https re-validated
// Rust-side) instead. In a plain browser: a normal new tab.
//
// One of the three modules allowed to touch Tauri IPC (see keychain.ts's
// header comment — the grep-able boundary).
import { invoke } from '@tauri-apps/api/core';
import { inDesktop } from '$lib/keychain';

/** Best-effort — never throws; a non-http(s) `url` is dropped rather than forwarded anywhere. */
export function openExternal(url: string): void {
  if (!/^https?:\/\//i.test(url)) return;

  if (inDesktop()) {
    invoke('open_external', { url }).catch(() => {
      // Nothing actionable for the caller — same quiet posture as keychain.ts.
    });
  } else {
    window.open(url, '_blank', 'noopener,noreferrer');
  }
}
