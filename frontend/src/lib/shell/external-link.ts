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

/**
 * `openExternal` for a URL the caller does not have YET — call this
 * synchronously inside the click handler, then call what it returns with the
 * URL once it resolves (or `null` to abandon the open).
 *
 * It exists because of the browser half: `window.open` after an `await` is
 * what a popup blocker exists to stop, and losing the user's click to one is
 * both silent and unfixable from here. Reserving the tab while the gesture is
 * still on the stack and navigating it afterwards is the standard way out —
 * which also means NOT passing `noopener` (that makes `window.open` return
 * `null`, leaving nothing to navigate). Safe here specifically: the tab is
 * only ever pointed at Valea's own loopback origin, which serves these
 * responses `nosniff` under fixed non-HTML content types, so nothing that
 * could read back through `window.opener` ever executes in it.
 *
 * The desktop half has no such problem — `invoke` is not a popup — so it
 * simply defers to `openExternal` and reserves nothing.
 */
export function prepareExternalOpen(): (url: string | null) => void {
  if (inDesktop()) {
    return (url) => {
      if (url) openExternal(url);
    };
  }

  const reserved = window.open('', '_blank');

  return (url) => {
    if (!reserved) return;

    if (url && /^https?:\/\//i.test(url)) {
      reserved.location.href = url;
    } else {
      reserved.close();
    }
  };
}
