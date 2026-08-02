/**
 * Runs under the `runes` project (see `vite.config.ts`), which supplies the
 * client-transform environment.
 *
 * Deliberately NO per-file environment pragma. Vitest greps the whole file
 * for that directive and takes the next word as an environment NAME, so
 * merely mentioning the directive in prose is enough to make it resolve
 * something like `header` and fail the file before a single test runs. The
 * `at`-sigil spelling is avoided above for exactly that reason.
 * `tree-state.test.svelte.ts` carries no such line either.
 */
import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { flushSync } from 'svelte';
import { ThemeStore } from './theme.svelte';
import { THEME_STORAGE_KEY, type ThemePreference } from './theme';

let listeners: Array<(e: { matches: boolean }) => void> = [];
let prefersDark = false;

function installEnvironment(): void {
  const data = new Map<string, string>();
  Object.defineProperty(globalThis, 'localStorage', {
    value: {
      getItem: (k: string) => (data.has(k) ? data.get(k)! : null),
      setItem: (k: string, v: string) => void data.set(k, v),
      removeItem: (k: string) => void data.delete(k),
      clear: () => data.clear()
    },
    configurable: true,
    writable: true
  });
  listeners = [];
  Object.defineProperty(globalThis, 'matchMedia', {
    value: () => ({
      get matches() {
        return prefersDark;
      },
      addEventListener: (_: string, fn: (e: { matches: boolean }) => void) => listeners.push(fn),
      removeEventListener: (_: string, fn: (e: { matches: boolean }) => void) => {
        listeners = listeners.filter((l) => l !== fn);
      }
    }),
    configurable: true,
    writable: true
  });
  const classes = new Set<string>();
  Object.defineProperty(globalThis, 'document', {
    value: {
      documentElement: {
        classList: {
          add: (c: string) => classes.add(c),
          remove: (c: string) => classes.delete(c),
          contains: (c: string) => classes.has(c)
        },
        style: { colorScheme: '', background: '' }
      }
    },
    configurable: true,
    writable: true
  });
}

function teardown(): void {
  for (const g of ['localStorage', 'matchMedia', 'document']) {
    // @ts-expect-error - deliberately removing the globals
    delete globalThis[g];
  }
}

describe('ThemeStore', () => {
  beforeEach(() => {
    prefersDark = false;
    installEnvironment();
  });
  afterEach(() => teardown());

  it('defaults to system and resolves against the OS', () => {
    prefersDark = true;
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(store.resolved).toBe('dark');
  });

  it('follows an OS change while on system', () => {
    const store = new ThemeStore();
    const stop = store.start();
    expect(store.resolved).toBe('light');

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();

    expect(store.resolved).toBe('dark');
    stop();
  });

  it('ignores an OS change while pinned to light', () => {
    const store = new ThemeStore();
    const stop = store.start();
    store.setPreference('light');

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();

    expect(store.resolved).toBe('light');
    stop();
  });

  it('persists the preference and reloads it', () => {
    const store = new ThemeStore();
    store.setPreference('dark');
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('dark');
    expect(new ThemeStore().preference).toBe('dark');
  });

  it('applies the class and color-scheme to the document', () => {
    const store = new ThemeStore();
    const stop = store.start();

    store.setPreference('dark');
    flushSync();
    expect(document.documentElement.classList.contains('dark')).toBe(true);
    expect(document.documentElement.style.colorScheme).toBe('dark');

    store.setPreference('light');
    flushSync();
    expect(document.documentElement.classList.contains('dark')).toBe(false);
    expect(document.documentElement.style.colorScheme).toBe('light');
    stop();
  });

  /**
   * `static/theme-init.js` writes an inline background on `<html>` to cover
   * the pre-hydration paint. An inline style outranks the stylesheet, so if
   * the store left it there, `@layer base html { background: var(--paper-
   * surface) }` (layout.css) could never repaint the canvas: a light -> dark
   * switch would keep a cream canvas and overscroll region for the life of
   * the page, and Task 10 could not fix that drift by editing the token.
   *
   * Set the inline background back before each assertion — starting from the
   * stub's empty string would let this pass with the clearing line removed.
   */
  it('clears the pre-paint inline background so the stylesheet owns it', () => {
    const root = document.documentElement;
    root.style.background = '#fbf8f1';

    const store = new ThemeStore();
    const stop = store.start();
    flushSync();
    expect(root.style.background, 'start() must hand the background back to CSS').toBe('');

    root.style.background = '#fbf8f1';
    store.setPreference('dark');
    flushSync();
    expect(root.style.background, 'a theme change must not leave the launch colour pinned').toBe(
      ''
    );
    stop();
  });

  it('removes its media listener on stop, and does not double-register', () => {
    const store = new ThemeStore();
    const stop = store.start();
    expect(listeners.length).toBe(1);
    store.start();
    expect(listeners.length, 'a second start must not add a listener').toBe(1);
    stop();
    expect(listeners.length).toBe(0);
  });

  it('survives storage that throws on read and on write', () => {
    Object.defineProperty(globalThis, 'localStorage', {
      value: {
        getItem: () => {
          throw new Error('denied');
        },
        setItem: () => {
          throw new Error('denied');
        }
      },
      configurable: true,
      writable: true
    });
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(() => store.setPreference('dark')).not.toThrow();
    expect(store.preference).toBe('dark');
  });

  it('works with no localStorage at all', () => {
    // @ts-expect-error - deliberately removing the global
    delete globalThis.localStorage;
    const store = new ThemeStore();
    expect(store.preference).toBe('system');
    expect(() => store.setPreference('dark')).not.toThrow();
  });

  it('resyncs the OS answer on start, after a change it was not listening for', () => {
    const store = new ThemeStore();
    expect(store.resolved).toBe('light');

    // The OS flips while the store is stopped: nothing is subscribed, so the
    // change fires at nobody and `#systemDark` goes stale.
    prefersDark = true;

    const stop = store.start();
    expect(store.resolved, 'start() must re-ask the OS, not paint a stale answer').toBe('dark');
    expect(document.documentElement.classList.contains('dark')).toBe(true);
    stop();
  });

  it('sanitises an out-of-vocabulary preference on the way in', () => {
    const store = new ThemeStore();
    // Task 11 calls this with `value as ThemePreference` off a UI control.
    store.setPreference('DARK' as ThemePreference);
    expect(store.preference, 'memory must not hold what a reload would reject').toBe('system');
    expect(localStorage.getItem(THEME_STORAGE_KEY)).toBe('system');
  });
});

/**
 * Issue #4 again, in this store's own shape: a write path that reads its own
 * `$state` enrols the calling effect as a subscriber of what it just wrote.
 *
 * The live hazard here is NOT `setPreference` — the Appearance control calls
 * that from `onChange`, outside any tracking context. It is `start()`, which
 * calls `#apply()` synchronously in the body of the root layout's
 * `$effect(() => themeStore.start())`. Without the `untrack` in `#apply()`
 * that effect subscribes to `#preference` and `#systemDark` and re-runs on
 * every theme and OS change, tearing down and re-registering the media
 * listener each time.
 *
 * These are falsification tests: each negative one has been confirmed to FAIL
 * with the `untrack` removed (run counts 1/2/3 and 2/3 respectively), so none
 * of them can pass vacuously.
 */
describe('ThemeStore — the write paths must not subscribe their caller', () => {
  beforeEach(() => {
    prefersDark = false;
    installEnvironment();
  });
  afterEach(() => teardown());

  it('does not re-run the layout effect that owns start()', () => {
    const store = new ThemeStore();
    let runs = 0;

    // Exactly Task 11's root-layout shape: start() in the effect body, its
    // teardown returned as the effect's cleanup.
    const stopRoot = $effect.root(() => {
      $effect(() => {
        runs++;
        return store.start();
      });
    });
    flushSync();
    expect(runs).toBe(1);

    // The user picks a theme. SegmentedControl's onChange is not a tracking
    // context, but the effect above already ran #apply() — if that read was
    // tracked, this write wakes it.
    store.setPreference('dark');
    flushSync();
    expect(runs, 'a theme change must not re-run the effect that called start()').toBe(1);

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();
    expect(runs, 'an OS change must not re-run the effect that called start()').toBe(1);

    stopRoot();
  });

  it('does not subscribe an effect that calls setPreference to what it wrote', () => {
    const store = new ThemeStore();
    const stop = store.start();
    let runs = 0;

    const stopRoot = $effect.root(() => {
      $effect(() => {
        runs++;
        store.setPreference('dark');
      });
    });
    flushSync();
    // Without the untrack this is already 2: the effect self-invalidated on
    // its own write and only settled because the second write was ===-equal.
    expect(runs, 'writing must not invalidate the effect that wrote').toBe(1);

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();
    expect(runs, 'the OS must not wake an effect that only ever wrote').toBe(1);

    stopRoot();
    stop();
  });

  it('still wakes a reader that legitimately observes the resolved theme', () => {
    // The fix must not over-reach: `resolved` is what the Appearance UI and
    // any theme-dependent view render from, so it has to stay reactive to
    // BOTH cells it derives from.
    const store = new ThemeStore();
    const stop = store.start();
    const seen: string[] = [];

    const stopRoot = $effect.root(() => {
      $effect(() => void seen.push(store.resolved));
    });
    flushSync();

    prefersDark = true;
    listeners.forEach((fn) => fn({ matches: true }));
    flushSync();

    store.setPreference('light');
    flushSync();

    expect(seen).toEqual(['light', 'dark', 'light']);
    stopRoot();
    stop();
  });
});
