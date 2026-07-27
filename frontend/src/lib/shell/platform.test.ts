import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Same mocking posture as `stores/mail.test.ts`: the Tauri-detection
// primitive is stubbed at its module boundary so both branches of
// `overlayChrome` are drivable from vitest, where no webview exists.
vi.mock('../keychain', () => ({ inDesktop: vi.fn(() => false) }));

import { inDesktop } from '../keychain';
import { overlayChrome } from './platform';

// Real strings from the three webviews Valea ships in (WKWebView,
// WebView2, WebKitGTK) — the mac one is the only ARM/Intel-agnostic
// "Macintosh" carrier.
const MAC_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const WINDOWS_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';
const LINUX_UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36';

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

  it('is false in the desktop app on Windows (native decorations — no dead strip)', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(overlayChrome()).toBe(false);
  });

  it('is false in the desktop app on Linux (native decorations)', () => {
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
