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

  /**
   * `parsePreference` on the way IN as well as out. The UI hands this an
   * unchecked cast off a control's string (`setPreference(value as
   * ThemePreference)`), and an out-of-vocabulary value would otherwise be
   * held in memory AND written to storage, then sanitised to `'system'` on
   * the next load — store and storage disagreeing across a reload.
   */
  setPreference(preference: ThemePreference): void {
    this.#preference = parsePreference(preference);
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

    // Resync before painting. An OS change that landed while we were stopped —
    // between construction and `start()`, or across a stop/start — fired at
    // nobody, so `#systemDark` may be stale and `#apply()` would paint the old
    // answer until the next OS change happened to correct it.
    this.#systemDark = systemPrefersDark();
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
   * Untracked (issue #4). Do not remove this `untrack` — and do not judge it
   * by asking whether any effect calls `setPreference`, because none does:
   * the Appearance control calls that from an `onChange` handler, which is
   * not a tracking context.
   *
   * The live caller is `start()`, via the root layout's
   * `$effect(() => themeStore.start())`. `start()` calls `#apply()`
   * SYNCHRONOUSLY in that effect's body, so a tracked read here subscribes
   * the whole layout effect to `#preference` and `#systemDark` — the state
   * this store exists to write. The layout effect would then re-run on every
   * theme change and every OS change, tearing down and re-registering the
   * media listener each time.
   *
   * Both hazards are pinned, and both tests fail if this `untrack` goes:
   * "does not re-run the layout effect that owns start()" and "does not
   * subscribe an effect that calls setPreference to what it wrote", in
   * `theme.test.svelte.ts`. Untracking a read never suppresses a
   * NOTIFICATION: `resolved` still reads both tracked, so genuine observers
   * still wake — "still wakes a reader that observes the resolved theme"
   * holds that line.
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
    // Untracked for the same reason as `#apply()`, but pinned by only one of
    // its tests: `start()` never persists, so only "does not subscribe an
    // effect that calls setPreference to what it wrote" fails if this goes.
    const value = untrack(() => this.#preference);
    try {
      localStorage.setItem(THEME_STORAGE_KEY, value);
    } catch {
      // Storage full/denied — the choice just stays session-local.
    }
  }
}

export const themeStore = new ThemeStore();
