/**
 * `static/theme-init.js` duplicates the storage key, the class name and the
 * resolution branch, because it cannot import from the bundle without
 * becoming render-blocking. This pins the duplication: the real file is
 * evaluated against stubbed globals and must agree with `resolveTheme` on
 * every combination.
 */
import { describe, it, expect } from 'vitest';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolveTheme, THEME_STORAGE_KEY, DARK_CLASS, type ThemePreference } from './theme';
import { readPalette } from '../design/tokens';

const SCRIPT = readFileSync(
  fileURLToPath(new URL('../../../static/theme-init.js', import.meta.url)),
  'utf8'
);

type RunResult = { classes: Set<string>; colorScheme: string; background: string };

function run(
  stored: string | null,
  prefersDark: boolean,
  opts: { throwOnRead?: boolean; throwOnMedia?: boolean } = {}
): RunResult {
  const classes = new Set<string>();
  const root = {
    classList: { add: (c: string) => classes.add(c), remove: (c: string) => classes.delete(c) },
    style: { colorScheme: '', background: '' }
  };
  const sandbox = {
    document: { documentElement: root },
    localStorage: {
      getItem: (k: string) => {
        if (opts.throwOnRead) throw new Error('denied');
        return k === THEME_STORAGE_KEY ? stored : null;
      }
    },
    matchMedia: () => {
      if (opts.throwOnMedia) throw new Error('denied');
      return { matches: prefersDark };
    }
  };
  new Function('document', 'localStorage', 'matchMedia', SCRIPT)(
    sandbox.document,
    sandbox.localStorage,
    sandbox.matchMedia
  );
  return { classes, colorScheme: root.style.colorScheme, background: root.style.background };
}

describe('theme-init.js', () => {
  const cases: Array<[ThemePreference | null, boolean]> = [
    ['light', false],
    ['light', true],
    ['dark', false],
    ['dark', true],
    ['system', false],
    ['system', true]
  ];

  it.each(cases)('agrees with resolveTheme for %s / prefersDark=%s', (pref, prefersDark) => {
    const expected = resolveTheme(pref as ThemePreference, prefersDark);
    const result = run(pref, prefersDark);
    expect(result.classes.has(DARK_CLASS)).toBe(expected === 'dark');
    expect(result.colorScheme).toBe(expected);
  });

  it('treats a missing key as system', () => {
    expect(run(null, true).classes.has(DARK_CLASS)).toBe(true);
    expect(run(null, false).classes.has(DARK_CLASS)).toBe(false);
  });

  it('treats an unrecognised value as system', () => {
    expect(run('DARK', true).classes.has(DARK_CLASS)).toBe(true);
  });

  /**
   * Storage denied means "no preference recorded", which is `'system'` — the
   * same answer `readStored()` in `theme.svelte.ts` gives. The script must
   * agree with the store or hydration repaints, i.e. the flash this file
   * exists to prevent. What the guard buys is that it never throws.
   */
  it('never throws when storage is denied, and still follows the system', () => {
    const light = run(null, false, { throwOnRead: true });
    expect(light.classes.has(DARK_CLASS)).toBe(false);
    expect(light.colorScheme).toBe('light');

    const dark = run(null, true, { throwOnRead: true });
    expect(dark.classes.has(DARK_CLASS)).toBe(true);
    expect(dark.colorScheme).toBe('dark');
  });

  it('falls back to light when matchMedia throws', () => {
    const result = run(null, true, { throwOnMedia: true });
    expect(result.classes.has(DARK_CLASS)).toBe(false);
    expect(result.colorScheme).toBe('light');
  });

  it('sets a background so the first paint is not white', () => {
    expect(run('dark', false).background).not.toBe('');
  });

  /**
   * The script hardcodes its two pre-paint backgrounds — it runs before
   * `layout.css` lands, so it cannot read a custom property that does not
   * exist yet. Nothing else ties those literals to the palettes, and if they
   * drift the launch shows a one-frame colour change: exactly the flash this
   * file exists to prevent, and only on a cold start, so it survives review.
   * So read both blocks out of `layout.css` and pin the literals to them.
   */
  it('pre-paints the real --paper-surface of each palette', () => {
    const light = readPalette('light')['paper-surface'];
    const dark = readPalette('dark')['paper-surface'];
    expect(light, 'light palette must define --paper-surface').toBeDefined();
    expect(dark, 'dark palette must define --paper-surface').toBeDefined();

    expect(run('light', false).background, "the script's light literal").toBe(light);
    expect(run('dark', false).background, "the script's dark literal").toBe(dark);
  });
});

describe('app.html', () => {
  const html = readFileSync(fileURLToPath(new URL('../../app.html', import.meta.url)), 'utf8');

  it('loads the script as an external file, not inline', () => {
    expect(html).toContain('theme-init.js');
    expect(html, 'an inline theme script would be CSP-blocked in production').not.toMatch(
      /<script(?![^>]*\bsrc=)[^>]*>[\s\S]*valea\.theme/
    );
  });

  it('no longer hardcodes the light theme', () => {
    expect(html).not.toContain('background:#fbf8f1');
    expect(html).not.toMatch(/name="color-scheme"\s+content="light"/);
  });
});
