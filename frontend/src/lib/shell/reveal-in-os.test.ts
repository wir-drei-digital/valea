import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Same mocking posture as `platform.test.ts`: the Tauri-detection primitive
// is stubbed at its module boundary so every branch of `revealLabel` (via
// `windowChrome`) is drivable from vitest, where no webview exists.
vi.mock('../keychain', () => ({ inDesktop: vi.fn(() => false) }));

import { inDesktop } from '../keychain';
import { absPathFor, revealLabel } from './reveal-in-os';

const mounts = [
  { mountKey: 'work', root: '/Users/d/ICMs/Work' },
  { mountKey: 'life', root: '/Users/d/ICMs/Life/' }
];

describe('absPathFor', () => {
  it('joins the mount root with the ICM-relative path', () => {
    expect(absPathFor(mounts, 'work', 'Clients/acme.md')).toBe('/Users/d/ICMs/Work/Clients/acme.md');
  });

  it('does not double the separator when the root carries a trailing slash', () => {
    expect(absPathFor(mounts, 'life', 'notes.md')).toBe('/Users/d/ICMs/Life/notes.md');
  });

  it('answers the mount root itself for the empty path', () => {
    expect(absPathFor(mounts, 'work', '')).toBe('/Users/d/ICMs/Work');
  });

  it('returns null for an unknown mount, so the caller offers nothing rather than aiming at a wrong path', () => {
    expect(absPathFor(mounts, 'gone', 'notes.md')).toBeNull();
  });

  it('returns null for a mount with no resolved root', () => {
    expect(absPathFor([{ mountKey: 'broken', root: '' }], 'broken', 'a.md')).toBeNull();
  });

  it('returns null for a relPath carrying a .. segment, however deep', () => {
    expect(absPathFor(mounts, 'work', '../../etc')).toBeNull();
    expect(absPathFor(mounts, 'work', 'Clients/../../../etc/passwd')).toBeNull();
  });

  it('returns null for an absolute relPath', () => {
    expect(absPathFor(mounts, 'work', '/etc/passwd')).toBeNull();
  });

  it('allows a filename that merely contains dots, as long as no segment IS ..', () => {
    expect(absPathFor(mounts, 'work', '..notes.md')).toBe('/Users/d/ICMs/Work/..notes.md');
    expect(absPathFor(mounts, 'work', 'foo..bar')).toBe('/Users/d/ICMs/Work/foo..bar');
  });
});

// The three webviews Valea ships in, in the shape each actually reports —
// same strings `platform.test.ts` drives `windowChrome` with, since
// `revealLabel` is just a switch over its answer.
const MAC_UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Safari/605.1.15';
const WINDOWS_UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Safari/537.36 Edg/130.0.0.0';
const LINUX_UA =
  'Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/8.0 Safari/605.1.15';

beforeEach(() => {
  vi.mocked(inDesktop).mockReset().mockReturnValue(false);
});

afterEach(() => {
  vi.unstubAllGlobals();
});

describe('revealLabel', () => {
  it('names Finder on macOS', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(revealLabel()).toBe('Reveal in Finder');
  });

  it('names Explorer on Windows', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(revealLabel()).toBe('Show in Explorer');
  });

  // Linux has no single file manager to name, so it gets the generic phrase
  // rather than guessing wrong for whichever one the user actually runs.
  it('uses the generic phrase on Linux', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: LINUX_UA });
    expect(revealLabel()).toBe('Show in file manager');
  });

  // Outside the desktop app `windowChrome()` short-circuits to 'browser'
  // whatever the UA — the fallback branch of `revealLabel`'s switch.
  it('uses the generic phrase in the browser too, whatever the UA', () => {
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(revealLabel()).toBe('Show in file manager');
  });
});
