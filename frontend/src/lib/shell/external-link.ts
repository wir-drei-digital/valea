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
 * `null`, leaving nothing to navigate). So the reserved tab starts out with a
 * live `window.opener` back-reference to this one, and `opener` is nulled
 * immediately before the navigation to sever it — the callback's one job
 * besides pointing the tab somewhere.
 *
 * That matters because of WHERE these tabs go. Since M6 the URL is a THIRD
 * PARTY's consent page (`accounts.google.com`, `login.microsoftonline.com` —
 * `startMailSignIn`, browser dev only; the desktop half routes through
 * `open_external`), not Valea's own loopback origin as this comment used to
 * claim. A page reached through an `opener` can navigate the window that
 * opened it (`opener.location = …`) — a real phishing primitive on a
 * sign-in page, and a consent flow is exactly where a redirect through some
 * unexpected host can end up rendering. Nulling `opener` first costs nothing
 * and takes the whole class off the table, whatever the URL turns out to be.
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
      // BEFORE the navigation, never after: the destination must never get a
      // window it can steer (see this function's doc comment).
      reserved.opener = null;
      reserved.location.href = url;
    } else {
      reserved.close();
    }
  };
}
