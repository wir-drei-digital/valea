import { describe, expect, it } from 'vitest';
import {
  canAddSplit,
  closeSplit,
  dropVanished,
  firstUnopenedLeaf,
  openAsSecond,
  openInFirst
} from './files-pane-state';
import type { NavTreeItem } from '$lib/shell/nav';

describe('openInFirst', () => {
  it('opens into an empty pane', () => {
    expect(openInFirst([], 'A.md', 2)).toEqual(['A.md']);
  });

  it('replaces the first split, leaving the second alone', () => {
    expect(openInFirst(['A.md', 'B.md'], 'C.md', 2)).toEqual(['C.md', 'B.md']);
  });

  it('is a no-op when the file is already in the first split', () => {
    expect(openInFirst(['A.md'], 'A.md', 2)).toEqual(['A.md']);
  });

  it('moves focus rather than duplicating when the file is already in the second split', () => {
    expect(openInFirst(['A.md', 'B.md'], 'B.md', 2)).toEqual(['A.md', 'B.md']);
  });

  // `maxSplits` is width-derived (`splitsThatFit`), so a pane that narrowed to
  // one split must shed the second on the next tree click rather than keep
  // rendering a split that no longer fits.
  it('drops the second split when the width now allows only one', () => {
    expect(openInFirst(['A.md', 'B.md'], 'C.md', 1)).toEqual(['C.md']);
  });

  // A descriptor carrying three paths serializes to `files:m/a|b|c`, which
  // `parsePaneParam` rejects — the pane would silently vanish from the URL.
  // The cap is absolute, not merely whatever the caller passed.
  it('never grows past the hard split cap even when told a larger maximum', () => {
    expect(openInFirst(['A.md', 'B.md'], 'C.md', 3)).toEqual(['C.md', 'B.md']);
    expect(openInFirst(['A.md', 'B.md', 'C.md'], 'D.md', 3)).toEqual(['D.md', 'B.md']);
  });
});

describe('openAsSecond', () => {
  it('adds a second split', () => {
    expect(openAsSecond(['A.md'], 'B.md', 2)).toEqual(['A.md', 'B.md']);
  });

  it('replaces the second when both are taken', () => {
    expect(openAsSecond(['A.md', 'B.md'], 'C.md', 2)).toEqual(['A.md', 'C.md']);
  });

  it('behaves like openInFirst on an empty pane', () => {
    expect(openAsSecond([], 'A.md', 2)).toEqual(['A.md']);
  });

  it('refuses to exceed the width-derived cap', () => {
    expect(openAsSecond(['A.md'], 'B.md', 1)).toEqual(['B.md']);
  });

  it('never duplicates an already-open file', () => {
    expect(openAsSecond(['A.md'], 'A.md', 2)).toEqual(['A.md']);
  });

  // Same vanishing-descriptor hazard as above, on the function most likely to
  // grow the list: two open files plus a bogus maximum must still yield two.
  it('never grows past the hard split cap even when told a larger maximum', () => {
    expect(openAsSecond(['A.md', 'B.md'], 'C.md', 3)).toEqual(['A.md', 'C.md']);
  });

  it('opens nothing when the width allows no split at all', () => {
    expect(openAsSecond([], 'A.md', 0)).toEqual([]);
  });
});

describe('closeSplit', () => {
  it('removes the split at the index', () => {
    expect(closeSplit(['A.md', 'B.md'], 0)).toEqual(['B.md']);
    expect(closeSplit(['A.md', 'B.md'], 1)).toEqual(['A.md']);
  });

  it('leaves a tree-only pane when the last split closes', () => {
    expect(closeSplit(['A.md'], 0)).toEqual([]);
  });

  it('ignores an out-of-range index', () => {
    expect(closeSplit(['A.md'], 3)).toEqual(['A.md']);
    expect(closeSplit(['A.md'], -1)).toEqual(['A.md']);
  });
});

describe('canAddSplit', () => {
  it('is false at the cap and true below it', () => {
    expect(canAddSplit(['A.md', 'B.md'], 2)).toBe(false);
    expect(canAddSplit(['A.md'], 2)).toBe(true);
    expect(canAddSplit(['A.md'], 1)).toBe(false);
  });

  // The affordance must stay hidden at two splits however much width there is.
  it('is false at the hard cap regardless of the width-derived maximum', () => {
    expect(canAddSplit(['A.md', 'B.md'], 3)).toBe(false);
  });

  it('is false in a pane too narrow for any split', () => {
    expect(canAddSplit([], 0)).toBe(false);
  });
});

describe('dropVanished', () => {
  it('removes only the vanished file, keeping its sibling', () => {
    expect(dropVanished(['A.md', 'B.md'], 'A.md')).toEqual(['B.md']);
  });

  it('leaves the list untouched when nothing matches', () => {
    expect(dropVanished(['A.md'], 'Z.md')).toEqual(['A.md']);
  });

  it('empties a single-split pane whose only file was deleted', () => {
    expect(dropVanished(['A.md'], 'A.md')).toEqual([]);
  });
});

describe('firstUnopenedLeaf', () => {
  // Only the fields the walk actually reads; `icmToNav` produces the rest.
  function leaf(path: string): NavTreeItem {
    return { label: path, href: `/knowledge/m/${path}`, path, mountKey: 'm' };
  }

  function folder(path: string, children: NavTreeItem[]): NavTreeItem {
    return { label: path, href: `/knowledge/m/${path}`, path, mountKey: 'm', children };
  }

  it('picks the first leaf in display order', () => {
    expect(firstUnopenedLeaf([leaf('A.md'), leaf('B.md')], [])).toBe('A.md');
  });

  it('skips leaves already open in a split', () => {
    expect(firstUnopenedLeaf([leaf('A.md'), leaf('B.md')], ['A.md'])).toBe('B.md');
  });

  // A root of nothing but folders is the common shape of a real ICM, so a
  // walk that only looked at the top level would hand the header button
  // nothing to open in exactly the trees people have.
  it('descends into folders, depth first', () => {
    const nodes = [folder('notes', [leaf('notes/one.md')]), leaf('top.md')];
    expect(firstUnopenedLeaf(nodes, [])).toBe('notes/one.md');
  });

  it('moves on to the next branch when a whole folder is already open', () => {
    const nodes = [folder('notes', [leaf('notes/one.md')]), leaf('top.md')];
    expect(firstUnopenedLeaf(nodes, ['notes/one.md'])).toBe('top.md');
  });

  // An unloaded folder arrives as `children: []`. It must not be mistaken for
  // a leaf — opening a FOLDER path in a split would render a file view over
  // something that is not a file.
  it('treats an empty folder as a folder, not a leaf', () => {
    expect(firstUnopenedLeaf([folder('empty', []), leaf('A.md')], [])).toBe('A.md');
    expect(firstUnopenedLeaf([folder('empty', [])], [])).toBeNull();
  });

  it('returns null when every leaf is already open', () => {
    expect(firstUnopenedLeaf([leaf('A.md'), leaf('B.md')], ['A.md', 'B.md'])).toBeNull();
  });

  it('returns null for an empty tree', () => {
    expect(firstUnopenedLeaf([], [])).toBeNull();
  });
});
