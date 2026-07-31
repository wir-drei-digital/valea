import { describe, expect, it } from 'vitest';
import { closeSplit, dropVanished, openAsSecond, openInFirst } from './files-pane-state';

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

  // THE laptop bug. `splitsThatFit` needs TREE_W + SPLIT_MIN = 540px of pane
  // before ONE split fits, which a two-pane row does not reach until roughly a
  // 1590px window — so on a 1440x900 or a MacBook Pro 14" the cap is 0 and
  // every click in the pane's own tree used to do nothing at all.
  it('opens the first file even when the width allows no split at all', () => {
    expect(openInFirst([], 'A.md', 0)).toEqual(['A.md']);
  });

  // The floor is for the FIRST file only: it must not become a back door that
  // grows a second split the width cannot hold.
  it('still refuses a second split at that width, replacing instead', () => {
    expect(openInFirst(['A.md'], 'B.md', 0)).toEqual(['B.md']);
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

  // Reversed deliberately (this test previously asserted `[]`). "Open beside"
  // on a row of an EMPTY pane is the same click as the row itself, and the
  // width cap governs how many files sit side by side — not whether the pane
  // may show one. See the module header for the widths this stranded.
  it('opens the first file even when the width allows no split at all', () => {
    expect(openAsSecond([], 'A.md', 0)).toEqual(['A.md']);
  });

  it('still refuses to add a second split at that width, replacing instead', () => {
    expect(openAsSecond(['A.md'], 'B.md', 0)).toEqual(['B.md']);
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
