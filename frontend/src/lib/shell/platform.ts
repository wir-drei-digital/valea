/**
 * Which window chrome the shell is drawing itself into (windows-support
 * spec §E2).
 *
 * `tauri.conf.json`'s `titleBarStyle: "Overlay"` + `hiddenTitle` +
 * `trafficLightPosition` are **macOS-only** keys — Tauri ignores them
 * everywhere else, so Windows and Linux windows come up with ordinary
 * native decorations and no traffic lights. Any layout that compensates
 * for the overlay (the sidebar's tall brand band, a fixed
 * `data-tauri-drag-region` strip across the top) must therefore key on
 * "macOS overlay", NOT on `inDesktop()` — which is equally true on
 * Windows, where the same compensation would leave a dead ~48px strip
 * under a real title bar.
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
 * (no `navigator`) and browser dev both answer `false` without touching
 * the UA.
 */
import { inDesktop } from '../keychain';

/** True only in the packaged desktop app on macOS, where the title bar is an overlay the SPA draws under. */
export function overlayChrome(): boolean {
  return inDesktop() && navigator.userAgent.includes('Macintosh');
}
