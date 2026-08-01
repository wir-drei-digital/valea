/**
 * Which window chrome the shell is drawing itself into (windows-support
 * spec §E2).
 *
 * `tauri.conf.json`'s `titleBarStyle: "Overlay"` + `hiddenTitle` +
 * `trafficLightPosition` are **macOS-only** keys — Tauri ignores them
 * everywhere else. Windows and Linux reach the same chromeless top edge a
 * different way: `decorations: false`, which removes the native frame
 * outright and leaves no OS-drawn buttons at all, so the SPA owes those
 * windows min/max/close of its own.
 *
 * The layouts that compensate for that top edge — the sidebar's tall brand
 * band, the fixed `data-tauri-drag-region` strip — were gated on plain
 * `inDesktop()`, never on the overlay, so they already rendered on Windows
 * and Linux, where the ~48px band was dead space beside a real title bar
 * until `decorations: false` landed. `windowChrome()` is what makes that
 * deliberate: it names the chrome the window actually has instead of the
 * runtime it happens to be in, so a layout can say which of the four
 * presentations it is compensating for.
 *
 * UA sniffing rather than `@tauri-apps/plugin-os`: this decides
 * presentation only (never a security or capability gate), it must answer
 * synchronously during render, and across the three webviews Valea ships
 * in — WKWebView, WebView2, WebKitGTK — only the mac one says
 * "Macintosh". A wrong answer costs padding, nothing else. Adding an
 * async platform round-trip (and a plugin permission) for that would be
 * the worse trade.
 *
 * `inDesktop()` is checked first and short-circuits, so SSR/prerender
 * (no `navigator`) and browser dev both answer `'browser'` without
 * touching the UA.
 */
import { inDesktop } from '../keychain';

/**
 * Which window chrome the shell is drawing itself into.
 *
 * Four answers, not two: `decorations: false` gives Windows and Linux their own
 * frameless chrome, so "is this the macOS overlay" stopped being enough.
 *
 *   'browser'       — a real browser tab. Draws no window furniture.
 *   'macos-overlay' — `titleBarStyle: "Overlay"`: the OS still draws the
 *                     traffic lights, the SPA draws under them.
 *   'windows'       — frameless. The SPA draws min/max/close itself.
 *   'linux'         — frameless, same, GNOME-inspired.
 *
 * An unrecognised desktop UA answers `'browser'` on purpose. It is the only
 * value that draws nothing, and drawing our own controls over a real title bar
 * is a worse failure than drawing none.
 */
export type WindowChrome = 'browser' | 'macos-overlay' | 'windows' | 'linux';

export function windowChrome(): WindowChrome {
  if (!inDesktop()) return 'browser';
  const ua = navigator.userAgent;
  if (ua.includes('Macintosh')) return 'macos-overlay';
  if (ua.includes('Windows')) return 'windows';
  if (ua.includes('Linux') || ua.includes('X11')) return 'linux';
  return 'browser';
}

/** True only where the OS draws the title bar and the SPA draws under it. */
export function overlayChrome(): boolean {
  return windowChrome() === 'macos-overlay';
}
