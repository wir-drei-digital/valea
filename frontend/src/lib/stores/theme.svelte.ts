/**
 * The theme preference: what the user chose, what that resolves to right
 * now, and getting it onto `<html>`.
 *
 * Persisted to `localStorage` under `valea.theme` with the same guarded
 * posture as `recent-pages.ts` and `tree-state.svelte.ts` — no storage (SSR,
 * tests, a locked-down WebView) means the choice is session-local, never an
 * error. Per-machine on purpose: `localStorage` is the only store readable
 * early enough for `static/theme-init.js` to beat first paint.
 *
 * `start()` is called once by the root layout. The `matchMedia` listener
 * stays attached whatever the preference, so switching back to `'system'`
 * is immediately correct rather than correct at the next OS change.
 */
import { untrack } from 'svelte';
import {
  DARK_CLASS,
  THEME_STORAGE_KEY,
  parsePreference,
  resolveTheme,
  type ResolvedTheme,
  type ThemePreference
} from './theme';

const MEDIA_QUERY = '(prefers-color-scheme: dark)';

function hasLocalStorage(): boolean {
  return typeof localStorage !== 'undefined';
}

function readStored(): ThemePreference {
  if (!hasLocalStorage()) return 'system';
  try {
    return parsePreference(localStorage.getItem(THEME_STORAGE_KEY));
  } catch {
    return 'system';
  }
}

function systemPrefersDark(): boolean {
  if (typeof matchMedia === 'undefined') return false;
  try {
    return matchMedia(MEDIA_QUERY).matches;
  } catch {
    return false;
  }
}

export class ThemeStore {
  #preference = $state<ThemePreference>(readStored());
  #systemDark = $state<boolean>(systemPrefersDark());
  #stop: (() => void) | null = null;

  get preference(): ThemePreference {
    return this.#preference;
  }

  get resolved(): ResolvedTheme {
    return resolveTheme(this.#preference, this.#systemDark);
  }

  setPreference(preference: ThemePreference): void {
    this.#preference = preference;
    this.#persist();
    this.#apply();
  }

  /**
   * Attach to the OS and paint the current answer. Returns a teardown.
   * Idempotent: calling it twice must not register a second listener, or an
   * HMR reload would leave the old one attached to a dead store.
   */
  start(): () => void {
    if (this.#stop) return this.#stop;

    this.#apply();

    if (typeof matchMedia === 'undefined') {
      this.#stop = () => {
        this.#stop = null;
      };
      return this.#stop;
    }

    const query = matchMedia(MEDIA_QUERY);
    const onChange = (event: { matches: boolean }): void => {
      this.#systemDark = event.matches;
      this.#apply();
    };
    query.addEventListener('change', onChange);

    this.#stop = () => {
      query.removeEventListener('change', onChange);
      this.#stop = null;
    };
    return this.#stop;
  }

  /**
   * Untracked (issue #4): reading `#preference`/`#systemDark` here would
   * enrol any effect that calls `setPreference` as a subscriber of the state
   * it just wrote.
   */
  #apply(): void {
    if (typeof document === 'undefined') return;
    const resolved = untrack(() => resolveTheme(this.#preference, this.#systemDark));
    const root = document.documentElement;
    if (resolved === 'dark') root.classList.add(DARK_CLASS);
    else root.classList.remove(DARK_CLASS);
    root.style.colorScheme = resolved;
  }

  #persist(): void {
    if (!hasLocalStorage()) return;
    const value = untrack(() => this.#preference);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, value);
    } catch {
      // Storage full/denied — the choice just stays session-local.
    }
  }
}

export const themeStore = new ThemeStore();
