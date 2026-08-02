// @vitest-environment - runs under the `runes` project (vite.config.ts)
import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest';
import { flushSync } from 'svelte';
import { ThemeStore } from './theme.svelte';
import { THEME_STORAGE_KEY } from './theme';

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
        style: { colorScheme: '' }
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
});
