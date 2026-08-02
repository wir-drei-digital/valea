import { describe, it, expect, beforeEach, afterEach } from 'vitest';
import { resolveTheme, parsePreference, THEME_STORAGE_KEY } from './theme';

function installFakeLocalStorage(): void {
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
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately removing the global
  delete globalThis.localStorage;
}

describe('resolveTheme', () => {
  it('follows the OS only when the preference is system', () => {
    expect(resolveTheme('system', true)).toBe('dark');
    expect(resolveTheme('system', false)).toBe('light');
  });

  it('ignores the OS when pinned', () => {
    expect(resolveTheme('light', true)).toBe('light');
    expect(resolveTheme('dark', false)).toBe('dark');
  });
});

describe('parsePreference', () => {
  it('accepts the three valid values', () => {
    expect(parsePreference('light')).toBe('light');
    expect(parsePreference('dark')).toBe('dark');
    expect(parsePreference('system')).toBe('system');
  });

  it('falls back to system for anything else', () => {
    for (const bad of ['DARK', ' dark ', '', null, undefined, 42, {}, ['dark']]) {
      expect(parsePreference(bad)).toBe('system');
    }
  });
});

describe('storage key', () => {
  beforeEach(() => installFakeLocalStorage());
  afterEach(() => removeLocalStorage());

  it('is the key the pre-paint script also uses', () => {
    // theme-init.js hardcodes this string; theme-init.test.ts pins that they agree.
    expect(THEME_STORAGE_KEY).toBe('valea.theme');
  });
});
