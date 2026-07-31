import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import { loadFilesSplit, loadPaneLayout, saveFilesSplit, savePaneLayout } from './pane-split';

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

describe('per-count pane layouts', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('keeps two-pane and three-pane arrangements independently', () => {
    savePaneLayout(2, [60, 40]);
    savePaneLayout(3, [50, 25, 25]);
    expect(loadPaneLayout(2)).toEqual([60, 40]);
    expect(loadPaneLayout(3)).toEqual([50, 25, 25]);
  });

  it('returns null for a count never saved, so the group uses its defaults', () => {
    expect(loadPaneLayout(3)).toBeNull();
  });

  it('rejects a stored layout whose length no longer matches the count', () => {
    localStorage.setItem('valea.pane-split.2', JSON.stringify([50, 25, 25]));
    expect(loadPaneLayout(2)).toBeNull();
  });

  it('rejects a stored layout containing a non-finite entry', () => {
    localStorage.setItem('valea.pane-split.2', JSON.stringify([50, null]));
    expect(loadPaneLayout(2)).toBeNull();
  });

  it('rejects unparseable and non-array stored values', () => {
    localStorage.setItem('valea.pane-split.2', 'junk');
    expect(loadPaneLayout(2)).toBeNull();
    localStorage.setItem('valea.pane-split.2', JSON.stringify({ 0: 50, 1: 50 }));
    expect(loadPaneLayout(2)).toBeNull();
  });

  // The writer guards too — a mismatched layout must never reach storage, or a
  // later load of the same count would have to reject its own written value.
  it('refuses to write a layout that does not match its count', () => {
    savePaneLayout(2, [50, 25, 25]);
    expect(loadPaneLayout(2)).toBeNull();
    savePaneLayout(2, [50, Number.NaN]);
    expect(loadPaneLayout(2)).toBeNull();
  });

  it('persists the Files pane split ratio under its own key', () => {
    saveFilesSplit(45);
    expect(loadFilesSplit()).toBe(45);
  });

  it('defaults the Files pane split to 40 and clamps to 20..70', () => {
    expect(loadFilesSplit()).toBe(40);
    saveFilesSplit(5);
    expect(loadFilesSplit()).toBe(20);
    saveFilesSplit(95);
    expect(loadFilesSplit()).toBe(70);
    saveFilesSplit(44.6);
    expect(loadFilesSplit()).toBe(45);
  });

  it('ignores a garbage Files split value', () => {
    localStorage.setItem('valea.files-split', 'junk');
    expect(loadFilesSplit()).toBe(40);
  });
});

describe('pane layouts — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('degrades to defaults and swallows the failed writes', () => {
    expect(loadPaneLayout(2)).toBeNull();
    expect(loadFilesSplit()).toBe(40);
    expect(() => savePaneLayout(2, [60, 40])).not.toThrow();
    expect(() => saveFilesSplit(45)).not.toThrow();
  });
});
