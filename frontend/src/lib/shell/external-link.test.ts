import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Both seams this module is allowed to touch, stubbed at their module
// boundaries (same posture as `platform.test.ts` and `keychain.test.ts`):
// the Tauri-detection primitive so the desktop branch is drivable, and
// `@tauri-apps/api/core` because there is no webview bridge under vitest.
vi.mock('$lib/keychain', () => ({ inDesktop: vi.fn(() => false) }));
vi.mock('@tauri-apps/api/core', () => ({ invoke: vi.fn(async () => undefined) }));

import { invoke } from '@tauri-apps/api/core';
import { inDesktop } from '$lib/keychain';
import { openExternal, prepareExternalOpen } from './external-link';

const CONSENT_URL = 'https://accounts.google.com/o/oauth2/v2/auth?client_id=valea';

/**
 * A stand-in for the tab `window.open('', '_blank')` hands back. Every write
 * the callback makes is appended to `writes` IN ORDER, which is the only way
 * to state "opener was severed BEFORE the navigation" as an assertion —
 * checking the end state alone would also pass if the two lines were swapped
 * (the destination would have had a live `opener` for the moment that
 * matters).
 */
function reservedTab() {
  const writes: string[] = [];
  // What the browser actually puts there: a live reference to the window that
  // reserved this tab.
  let opener: unknown = { name: 'the window that opened this tab' };
  let href = 'about:blank';

  return {
    writes,
    tab: {
      get opener() {
        return opener;
      },
      set opener(value: unknown) {
        opener = value;
        writes.push(`opener=${value === null ? 'null' : 'window'}`);
      },
      location: {
        get href() {
          return href;
        },
        set href(value: string) {
          href = value;
          writes.push(`href=${value}`);
        }
      },
      close: vi.fn(() => writes.push('close'))
    }
  };
}

function stubWindowOpen(result: unknown): ReturnType<typeof vi.fn> {
  const open = vi.fn(() => result);
  vi.stubGlobal('window', { open });
  return open;
}

beforeEach(() => {
  vi.mocked(inDesktop).mockReset().mockReturnValue(false);
  vi.mocked(invoke).mockReset().mockResolvedValue(undefined);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('openExternal', () => {
  it('opens a new browser tab with noopener,noreferrer in the browser', () => {
    const open = stubWindowOpen(null);

    openExternal('https://example.com/docs');

    expect(open).toHaveBeenCalledWith('https://example.com/docs', '_blank', 'noopener,noreferrer');
  });

  it('routes through the desktop crate instead of window.open in the app', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const open = stubWindowOpen(null);

    openExternal('https://example.com/docs');

    expect(invoke).toHaveBeenCalledWith('open_external', { url: 'https://example.com/docs' });
    expect(open).not.toHaveBeenCalled();
  });

  it('drops a non-http(s) url rather than forwarding it anywhere', () => {
    const open = stubWindowOpen(null);

    openExternal('javascript:alert(1)');
    openExternal('file:///etc/passwd');

    expect(open).not.toHaveBeenCalled();
    expect(invoke).not.toHaveBeenCalled();
  });
});

describe('prepareExternalOpen — browser (reserved tab)', () => {
  it('reserves the tab synchronously, WITHOUT noopener (there would be nothing left to navigate)', () => {
    const open = stubWindowOpen(reservedTab().tab);

    prepareExternalOpen();

    expect(open).toHaveBeenCalledWith('', '_blank');
  });

  it('severs window.opener BEFORE navigating the reserved tab to the consent page', () => {
    const { writes, tab } = reservedTab();
    stubWindowOpen(tab);

    const finish = prepareExternalOpen();
    finish(CONSENT_URL);

    // Order is the assertion: the third-party page must never see a live
    // opener, not even for the navigation that hands it the window.
    expect(writes).toEqual(['opener=null', `href=${CONSENT_URL}`]);
    expect(tab.opener).toBeNull();
    expect(tab.location.href).toBe(CONSENT_URL);
  });

  it('closes the reserved tab instead of parking a blank one when the url never arrives', () => {
    const { writes, tab } = reservedTab();
    stubWindowOpen(tab);

    prepareExternalOpen()(null);

    expect(tab.close).toHaveBeenCalled();
    expect(writes).toEqual(['close']);
  });

  it('closes the reserved tab on a non-http(s) url, touching neither opener nor location', () => {
    const { writes, tab } = reservedTab();
    stubWindowOpen(tab);

    prepareExternalOpen()('javascript:alert(1)');

    expect(tab.close).toHaveBeenCalled();
    expect(writes).toEqual(['close']);
  });

  it('is a no-op when the popup blocker refused the tab (nothing to navigate or close)', () => {
    stubWindowOpen(null);

    expect(() => prepareExternalOpen()(CONSENT_URL)).not.toThrow();
  });
});

describe('prepareExternalOpen — desktop', () => {
  it('reserves nothing and defers to openExternal (invoke is not a popup)', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const open = stubWindowOpen(reservedTab().tab);

    const finish = prepareExternalOpen();
    expect(open).not.toHaveBeenCalled();

    finish(CONSENT_URL);
    expect(invoke).toHaveBeenCalledWith('open_external', { url: CONSENT_URL });
  });

  it('does nothing at all when the url never arrives', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    stubWindowOpen(null);

    prepareExternalOpen()(null);

    expect(invoke).not.toHaveBeenCalled();
  });
});
