import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadPaneSplit, savePaneSplit } from './pane-split';

// This vitest setup runs on the default (node) environment, where the
// `localStorage` global is `null` rather than a Web Storage object — so the
// same in-memory stubbing pattern as `stores/tree-state.test.ts` applies
// here (see its header comment).
function installFakeLocalStorage(): void {
  const data = new Map<string, string>();
  const fake = {
    getItem: (key: string) => (data.has(key) ? data.get(key)! : null),
    setItem: (key: string, value: string) => {
      data.set(key, value);
    },
    removeItem: (key: string) => {
      data.delete(key);
    },
    clear: () => data.clear()
  };
  Object.defineProperty(globalThis, 'localStorage', { value: fake, configurable: true, writable: true });
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately deleting the global for the guard test
  delete globalThis.localStorage;
}

describe('pane split persistence', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('defaults to 60', () => {
    expect(loadPaneSplit()).toBe(60);
  });

  it('round-trips and clamps to 30..70', () => {
    savePaneSplit(55.4);
    expect(loadPaneSplit()).toBe(55);
    savePaneSplit(10);
    expect(loadPaneSplit()).toBe(30);
    savePaneSplit(95);
    expect(loadPaneSplit()).toBe(70);
  });

  it('ignores garbage stored values', () => {
    localStorage.setItem('valea.pane-split', 'junk');
    expect(loadPaneSplit()).toBe(60);
  });
});

describe('pane split — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('falls back to the default and swallows the failed write', () => {
    expect(loadPaneSplit()).toBe(60);
    expect(() => savePaneSplit(45)).not.toThrow();
  });
});
