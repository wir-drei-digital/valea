import { describe, expect, it } from 'vitest';
import { clampTreeWidth, panesThatFit, splitsThatFit, treeFits, truncateToFit } from './pane-fit';
import type { PaneDescriptor } from '$lib/panes/pane-route';

const a: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [], active: 0, compare: null };
const b: PaneDescriptor = { kind: 'chat', sessionId: 's1' };

describe('panesThatFit', () => {
  it('fits none when only the primary clears its minimum', () => {
    expect(panesThatFit(236 + 380, true)).toBe(0);
    expect(panesThatFit(900, true)).toBe(0);
  });

  it('fits one at primary + pane minimums', () => {
    expect(panesThatFit(236 + 380 + 300, true)).toBe(1);
  });

  it('fits two at primary + two pane minimums', () => {
    expect(panesThatFit(236 + 380 + 300 + 300, true)).toBe(2);
  });

  it('never exceeds the cap however wide the window', () => {
    expect(panesThatFit(6000, true)).toBe(2);
  });

  it('reclaims the nav width when the nav is collapsed', () => {
    expect(panesThatFit(380 + 300, false)).toBe(1);
  });

  it('is never negative on absurdly small windows', () => {
    expect(panesThatFit(0, true)).toBe(0);
  });

  // The minimums are inclusive: one pixel short of a boundary must drop a pane.
  it('drops the pane one pixel below each boundary', () => {
    expect(panesThatFit(236 + 380 + 300 - 1, true)).toBe(0);
    expect(panesThatFit(236 + 380 + 300 + 300 - 1, true)).toBe(1);
  });
});

// The widths here are written out as `TREE_W + SPLIT_MIN + …` rather than
// imported, deliberately: a test that computes its expectation from the same
// constant it is testing cannot notice the constant moving. These literals are
// the record of what the arithmetic is SUPPOSED to be, so a change to
// `SPLIT_MIN` has to come here and be argued for. It did — 300 to 240, when
// two files side by side turned out to be large-monitor-only.
//
// The tree width is now a NUMBER the caller measures rather than a boolean, so
// these pass the widths a tree actually renders at: 280 (`TREE_W`, where it
// opens) and 200 (`TREE_MIN`, the narrowest a drag can leave it).
describe('splitsThatFit', () => {
  it('fits one split beside the tree', () => {
    expect(splitsThatFit(280 + 240, 280)).toBe(1);
  });

  it('fits two splits beside the tree', () => {
    expect(splitsThatFit(280 + 240 + 240, 280)).toBe(2);
  });

  it('reclaims the tree width when the tree is hidden', () => {
    expect(splitsThatFit(280 + 240, 0)).toBe(2);
  });

  // A dragged tree changes the answer, which is the whole reason this takes a
  // width: the same pane fits a second column beside a narrow tree and not
  // beside a wide one.
  it('measures the tree the user dragged, not the one it opened at', () => {
    expect(splitsThatFit(200 + 240 + 240, 200)).toBe(2);
    expect(splitsThatFit(200 + 240 + 240, 440)).toBe(1);
  });

  it('caps at two', () => {
    expect(splitsThatFit(4000, 280)).toBe(2);
  });

  it('fits none when even one split would not clear its minimum', () => {
    expect(splitsThatFit(280 + 100, 280)).toBe(0);
  });

  it('drops the split one pixel below each boundary', () => {
    expect(splitsThatFit(280 + 240 - 1, 280)).toBe(0);
    expect(splitsThatFit(280 + 240 + 240 - 1, 280)).toBe(1);
  });

  // A split is a reading column, a pane is a whole surface — so a split's
  // minimum is deliberately BELOW `PANE_MIN`, and a pane width that fits one
  // pane fits more than one split.
  it('is narrower than a whole pane requires', () => {
    expect(splitsThatFit(300, 0)).toBe(1);
    expect(splitsThatFit(300 + 300, 0)).toBe(2);
  });

  it('is never negative on a pane narrower than the tree', () => {
    expect(splitsThatFit(0, 280)).toBe(0);
  });
});

// Same convention: `TREE_MIN` (200), `TREE_W` (280), `TREE_MAX` (480) and
// `SPLIT_MIN` (240) are written out.
describe('clampTreeWidth', () => {
  it('leaves a width the pane can afford alone', () => {
    expect(clampTreeWidth(320, 1000)).toBe(320);
  });

  it('holds the absolute bounds', () => {
    expect(clampTreeWidth(40, 4000)).toBe(200);
    expect(clampTreeWidth(9000, 4000)).toBe(480);
  });

  // THE reason the ceiling is pane-relative: without it a drag could take the
  // file column below `SPLIT_MIN`, which is exactly where `treeFits` hides the
  // tree — a resizer that disappears the thing you are resizing.
  it('never leaves the file column below a split minimum', () => {
    expect(clampTreeWidth(400, 560)).toBe(560 - 240);
    expect(treeFits(560, 1, clampTreeWidth(400, 560))).toBe(true);
  });

  // The squeeze bottoms out at TREE_MIN rather than following the pane down:
  // below that the pane genuinely cannot hold both, and `treeFits` — not this
  // — is what drops the tree.
  it('stops squeezing at the minimum, however narrow the pane', () => {
    expect(clampTreeWidth(400, 300)).toBe(200);
    expect(treeFits(300, 1, clampTreeWidth(400, 300))).toBe(false);
  });

  it('applies only the absolute bounds while the pane is unmeasured', () => {
    // Storage clamps with `paneWidth` 0 for exactly this reason: it has no
    // pane to be relative to.
    expect(clampTreeWidth(360, 0)).toBe(360);
    expect(clampTreeWidth(9000, 0)).toBe(480);
  });

  it('falls back to the default rather than propagating a NaN width', () => {
    expect(clampTreeWidth(Number.NaN, 1000)).toBe(280);
  });
});

describe('truncateToFit', () => {
  it('truncates from the right', () => {
    expect(truncateToFit([a, b], 236 + 380 + 300, true)).toEqual([a]);
  });

  it('returns everything when it all fits', () => {
    expect(truncateToFit([a, b], 1600, true)).toEqual([a, b]);
  });

  it('returns nothing when not even one pane fits', () => {
    expect(truncateToFit([a, b], 700, true)).toEqual([]);
  });

  // Callers keep the full list in memory, so the input must survive untouched.
  it('leaves the caller-owned array alone', () => {
    const panes = [a, b];
    truncateToFit(panes, 700, true);
    expect(panes).toEqual([a, b]);
  });
});

// Same convention as `splitsThatFit` above: the widths are written out rather
// than imported, so a constant that moves has to be argued for here.
describe('treeFits', () => {
  it('affords the tree once a split still clears its minimum beside it', () => {
    expect(treeFits(280 + 240, 1, 280)).toBe(true);
  });

  it('drops the tree one pixel below that', () => {
    // THE finding: an assistant-opened Files pane at a 900px window is 260px
    // wide, and a fixed `shrink-0` tree leaves the file a 20px column —
    // mounted, fetched, and completely invisible, for the price of a pane slot.
    expect(treeFits(280 + 240 - 1, 1, 280)).toBe(false);
    expect(treeFits(260, 1, 280)).toBe(false);
  });

  // Callers pass `clampTreeWidth`'s answer, which bottoms out at `TREE_MIN` —
  // so in practice the tree survives down to 440px of pane however wide the
  // user dragged it. Dragging is not a way to lose the navigator.
  it('holds on for a squeezed tree where a wide one would be dropped', () => {
    expect(treeFits(200 + 240, 1, 200)).toBe(true);
    expect(treeFits(200 + 240, 1, 480)).toBe(false);
  });

  it('affords the tree on an EMPTY pane at any width', () => {
    // There is no file to starve, and a pane with neither tree nor file is
    // the blank surface the blanket auto-hide proposal was rejected for.
    expect(treeFits(260, 0, 280)).toBe(true);
    expect(treeFits(1, 0, 280)).toBe(true);
  });

  it('affords the tree while the pane is unmeasured', () => {
    // `bind:clientWidth` reads 0 until the first ResizeObserver delivery.
    // Reading that as "infinitely narrow" would blink the tree out of every
    // Files pane on mount, including the wide ones.
    expect(treeFits(0, 1, 280)).toBe(true);
    expect(treeFits(-1, 1, 280)).toBe(true);
  });

  it('judges two open files by the same one-split floor', () => {
    // The question is whether the tree starves the file column, not whether
    // both files clear the minimum — `splitsThatFit` already caps that, and
    // truncating the row would close a file the user opened.
    expect(treeFits(280 + 240, 2, 280)).toBe(true);
    expect(treeFits(280 + 240 - 1, 2, 280)).toBe(false);
  });
});
