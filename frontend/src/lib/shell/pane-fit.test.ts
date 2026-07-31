import { describe, expect, it } from 'vitest';
import { panesThatFit, splitsThatFit, truncateToFit } from './pane-fit';
import type { PaneDescriptor } from '$lib/panes/pane-route';

const a: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [] };
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

describe('splitsThatFit', () => {
  it('fits one split beside the tree', () => {
    expect(splitsThatFit(240 + 300, true)).toBe(1);
  });

  it('fits two splits beside the tree', () => {
    expect(splitsThatFit(240 + 300 + 300, true)).toBe(2);
  });

  it('reclaims the tree width when the tree is hidden', () => {
    expect(splitsThatFit(300 + 300, false)).toBe(2);
  });

  it('caps at two', () => {
    expect(splitsThatFit(4000, true)).toBe(2);
  });

  it('fits none when even one split would not clear its minimum', () => {
    expect(splitsThatFit(240 + 100, true)).toBe(0);
  });

  it('drops the split one pixel below each boundary', () => {
    expect(splitsThatFit(240 + 300 - 1, true)).toBe(0);
    expect(splitsThatFit(240 + 300 + 300 - 1, true)).toBe(1);
  });

  it('is never negative on a pane narrower than the tree', () => {
    expect(splitsThatFit(0, true)).toBe(0);
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
