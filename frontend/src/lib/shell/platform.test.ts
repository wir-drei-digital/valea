import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Same mocking posture as `stores/mail.test.ts`: the Tauri-detection
// primitive is stubbed at its module boundary so every branch of
// `windowChrome` (and so of `overlayChrome`, which is expressed through it)
// is drivable from vitest, where no webview exists.
vi.mock('../keychain', () => ({ inDesktop: vi.fn(() => false) }));

import { inDesktop } from '../keychain';
import { overlayChrome, windowChrome } from './platform';

// The three webviews Valea ships in, in the shape each actually reports:
// WKWebView, WebView2 (Chromium, and it always appends the `Edg/` token that
// plain desktop Chrome lacks), WebKitGTK (same `AppleWebKit/605.1.15 …
// Version/x Safari/605.1.15` shape as WKWebView — which is exactly why
// "Macintosh", carried by neither of the other two and by both Apple
// silicon and Intel, is the token that separates them). Version numbers
// drift with the OS and the runtime; only the first parenthesis is
// load-bearing here.
const MAC_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const WINDOWS_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';
const LINUX_UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/8.0 Safari/605.1.15';

// WebKitGTK is not Linux-only: on a BSD the UA keeps `X11` and drops the
// `Linux` token altogether. Not a platform Valea ships to, but it is the
// realistic shape of a UA that reaches the `X11` half of `windowChrome`'s
// disjunct — `LINUX_UA` carries both tokens and `||` short-circuits, so
// without this string deleting `|| ua.includes('X11')` leaves the suite
// green.
const BSD_X11_UA =
  'Mozilla/5.0 (X11; FreeBSD amd64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/8.0 Safari/605.1.15';

beforeEach(() => {
  vi.mocked(inDesktop).mockReset().mockReturnValue(false);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('overlayChrome', () => {
  it('is false in the browser (dev server / vitest), whatever the UA', () => {
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(overlayChrome()).toBe(false);
  });

  it('is true in the desktop app on macOS (overlay title bar + traffic lights)', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(overlayChrome()).toBe(true);
  });

  it('is false in the desktop app on Windows (frameless, but not an overlay)', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(overlayChrome()).toBe(false);
  });

  it('is false in the desktop app on Linux (not an overlay either)', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: LINUX_UA });
    expect(overlayChrome()).toBe(false);
  });

  it('never reads the UA when not in the desktop app (short-circuits)', () => {
    const userAgent = vi.fn(() => MAC_UA);
    vi.stubGlobal('navigator', {
      get userAgent() {
        return userAgent();
      }
    });

    expect(overlayChrome()).toBe(false);
    expect(userAgent).not.toHaveBeenCalled();
  });
});

describe('windowChrome', () => {
  it('is browser outside the desktop app, whatever the UA', () => {
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(windowChrome()).toBe('browser');
  });

  it('names each desktop platform', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(windowChrome()).toBe('macos-overlay');
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(windowChrome()).toBe('windows');
    vi.stubGlobal('navigator', { userAgent: LINUX_UA });
    expect(windowChrome()).toBe('linux');
  });

  // Pins the `X11` half of the disjunct on its own — see `BSD_X11_UA`.
  it('names linux from X11 alone, with no Linux token', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: BSD_X11_UA });
    expect(windowChrome()).toBe('linux');
  });

  // SSR and prerender have no `navigator` at all; `inDesktop()` short-circuits
  // before it is touched, so this must not throw.
  it('is browser during SSR, with no navigator', () => {
    vi.stubGlobal('navigator', undefined);
    expect(windowChrome()).toBe('browser');
  });

  // An unrecognised desktop UA must not silently become 'windows' and start
  // drawing controls over a native title bar. Unknown falls back to the one
  // answer that draws nothing.
  it('falls back to browser for an unrecognised desktop UA', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: 'Mozilla/5.0 (Unknown)' });
    expect(windowChrome()).toBe('browser');
  });

  // The macOS regression guard: `overlayChrome` must keep answering exactly as
  // it did before this function existed.
  it('keeps overlayChrome in agreement', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(overlayChrome()).toBe(true);
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(overlayChrome()).toBe(false);
  });
});
