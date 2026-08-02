/**
 * The theme preference's vocabulary and its one rule.
 *
 * Split out of `theme.svelte.ts` deliberately: `resolveTheme` is the whole
 * decision and it is testable with no runes, no DOM and no store. The
 * pre-paint script (`static/theme-init.js`) reimplements this branch,
 * because it cannot import from the bundle without becoming
 * render-blocking; `theme-init.test.ts` pins the two together.
 */

export const THEME_STORAGE_KEY = 'valea.theme';

/** The class the pre-paint script and the store both put on `<html>`. */
export const DARK_CLASS = 'dark';

export type ThemePreference = 'light' | 'dark' | 'system';
export type ResolvedTheme = 'light' | 'dark';

export function resolveTheme(
  preference: ThemePreference,
  systemPrefersDark: boolean
): ResolvedTheme {
  if (preference === 'system') return systemPrefersDark ? 'dark' : 'light';
  return preference;
}

/**
 * Anything unrecognised is `'system'` — the same tolerance `tree-state`
 * gives corrupted JSON. A stored value is user data we did not validate on
 * the way in, and a theme is never worth throwing over.
 */
export function parsePreference(raw: unknown): ThemePreference {
  return raw === 'light' || raw === 'dark' || raw === 'system' ? raw : 'system';
}
