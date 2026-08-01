import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  defaultPaneLayout,
  loadFilesSplit,
  loadPaneLayout,
  loadTreeWidth,
  paneRowLayout,
  saveFilesSplit,
  savePaneLayout,
  saveTreeWidth
} from './pane-split';
import type { PaneDescriptor } from './pane-route';

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

  it('returns null for a count never saved, so the caller applies its own default', () => {
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

  // The writer guards too, and these assert on RAW storage rather than reading
  // back through `loadPaneLayout` — the reader's own guards would reject both
  // values whether or not the writer ever guarded, making a round-trip
  // assertion pass in both worlds. Nothing may reach the key at all.
  it('refuses to write a layout whose length does not match its count', () => {
    savePaneLayout(2, [50, 25, 25]);
    expect(localStorage.getItem('valea.pane-split.2')).toBeNull();
  });

  it('refuses to write a layout containing a non-finite entry', () => {
    savePaneLayout(2, [50, Number.NaN]);
    expect(localStorage.getItem('valea.pane-split.2')).toBeNull();
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

describe('default pane layouts', () => {
  it('gives a lone primary the whole row', () => {
    expect(defaultPaneLayout(1)).toEqual([100]);
  });

  it('opens a two-pane row at the 60/40 the app shipped with', () => {
    expect(defaultPaneLayout(2)).toEqual([60, 40]);
  });

  it('splits the remainder evenly between equal side panes', () => {
    expect(defaultPaneLayout(3)).toEqual([42, 29, 29]);
  });

  // paneforge normalises anything else, but a layout that does not sum to 100
  // means the row it opens at is not the row this function described.
  it('always sums to exactly 100', () => {
    for (const count of [1, 2, 3, 4, 5]) {
      const total = defaultPaneLayout(count).reduce((a, b) => a + b, 0);
      expect(total).toBe(100);
    }
  });

  // Reached only via a corrupt caller, but the return type promises a usable
  // layout, and `Array(-1)` would throw rather than degrade.
  it('degrades to a single full-width pane for a nonsense count', () => {
    expect(defaultPaneLayout(0)).toEqual([100]);
    expect(defaultPaneLayout(-3)).toEqual([100]);
    expect(defaultPaneLayout(Number.NaN)).toEqual([100]);
  });
});

describe('the layout a pane row opens at', () => {
  const files: PaneDescriptor = {
    kind: 'files',
    mountKey: 'work',
    paths: ['notes.md'],
    active: 0,
    compare: null
  };
  const chat: PaneDescriptor = { kind: 'chat', sessionId: 's1' };

  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('prefers the arrangement the user dragged for this pane count', () => {
    savePaneLayout(2, [80, 20]);
    expect(paneRowLayout([files])).toEqual([80, 20]);
  });

  // The row is sized by how many panes there are, not by which — two
  // different files side by side is still a two-column row.
  it('reads the same stored arrangement whatever the panes contain', () => {
    savePaneLayout(2, [80, 20]);
    expect(paneRowLayout([chat])).toEqual([80, 20]);
    expect(
      paneRowLayout([
        { kind: 'files', mountKey: 'work', paths: ['other.md'], active: 0, compare: null }
      ])
    ).toEqual([80, 20]);
  });

  it('falls back to the count default when this count was never dragged', () => {
    savePaneLayout(2, [80, 20]);
    expect(paneRowLayout([files, chat])).toEqual(defaultPaneLayout(3));
    expect(paneRowLayout([])).toEqual([100]);
  });

  // `loadPaneLayout` rejects a stored value whose length no longer matches;
  // the row still has to open at something usable.
  it('falls back to the count default when the stored arrangement is unusable', () => {
    localStorage.setItem('valea.pane-split.2', JSON.stringify([50, 25, 25]));
    expect(paneRowLayout([files])).toEqual([60, 40]);
    localStorage.setItem('valea.pane-split.2', 'junk');
    expect(paneRowLayout([files])).toEqual([60, 40]);
  });
});

// The bounds are written out (200 / 280 / 480) rather than imported, the same
// convention `pane-fit.test.ts` keeps: a test that computes its expectation
// from the constant it is testing cannot notice that constant moving.
describe('the files tree width', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });

  afterEach(() => removeLocalStorage());

  it('opens at the default until the user drags it', () => {
    expect(loadTreeWidth()).toBe(280);
  });

  it('round-trips a dragged width', () => {
    saveTreeWidth(330);
    expect(loadTreeWidth()).toBe(330);
  });

  // Asserted against RAW STORAGE, not through the reader: with only
  // `save(20) -> load() === 200` the reader's own clamp satisfies the
  // expectation whatever the writer did, and an unclamped writer would go
  // unnoticed until something else read the key.
  it('clamps on the way in', () => {
    saveTreeWidth(20);
    expect(localStorage.getItem('valea.files-tree-width')).toBe('200');
    saveTreeWidth(2000);
    expect(localStorage.getItem('valea.files-tree-width')).toBe('480');
  });

  it('clamps on the way out, so a hand-edited entry cannot widen the tree', () => {
    localStorage.setItem('valea.files-tree-width', '5000');
    expect(loadTreeWidth()).toBe(480);
    localStorage.setItem('valea.files-tree-width', '-40');
    expect(loadTreeWidth()).toBe(200);
  });

  it('falls back to the default for an unreadable entry', () => {
    localStorage.setItem('valea.files-tree-width', 'wide please');
    expect(loadTreeWidth()).toBe(280);
  });

  // Storage is shared by every Files pane, so it must not carry one pane's
  // ceiling: the pane-relative squeeze is `clampTreeWidth`'s job at render
  // time, and baking it in here would shrink every OTHER pane's tree to
  // whatever the narrowest one could afford.
  it('stores the preference, not one pane\'s squeeze', () => {
    saveTreeWidth(460);
    expect(loadTreeWidth()).toBe(460);
  });
});

describe('pane layouts — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('degrades to defaults and swallows the failed writes', () => {
    expect(loadPaneLayout(2)).toBeNull();
    expect(paneRowLayout([{ kind: 'chat', sessionId: 's1' }])).toEqual([60, 40]);
    expect(loadFilesSplit()).toBe(40);
    expect(loadTreeWidth()).toBe(280);
    expect(() => savePaneLayout(2, [60, 40])).not.toThrow();
    expect(() => saveFilesSplit(45)).not.toThrow();
    expect(() => saveTreeWidth(300)).not.toThrow();
  });
});
