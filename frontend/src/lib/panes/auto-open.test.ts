import { describe, expect, it } from 'vitest';
import { autoOpen, clearAuto, shiftAuto } from './auto-open';
import { closeSplit, dropVanished, openAsSecond } from './files-pane-state';

describe('autoOpen', () => {
  it('opens into an empty pane and claims that split', () => {
    expect(autoOpen([], null, 'A.md', 2)).toEqual({ paths: ['A.md'], autoIndex: 0 });
  });

  it('takes a free slot rather than replacing a user file', () => {
    expect(autoOpen(['USER.md'], null, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });

  it('recycles its own split instead of accumulating', () => {
    expect(autoOpen(['USER.md', 'A.md'], 1, 'B.md', 2)).toEqual({
      paths: ['USER.md', 'B.md'],
      autoIndex: 1
    });
  });

  it('does nothing when both splits are the user’s', () => {
    expect(autoOpen(['X.md', 'Y.md'], null, 'A.md', 2)).toEqual({
      paths: ['X.md', 'Y.md'],
      autoIndex: null
    });
  });

  it('does nothing when the width allows no split at all', () => {
    expect(autoOpen([], null, 'A.md', 0)).toEqual({ paths: [], autoIndex: null });
  });

  it('is a no-op when the file is already open, without stealing the claim', () => {
    expect(autoOpen(['A.md'], null, 'A.md', 2)).toEqual({ paths: ['A.md'], autoIndex: null });
  });

  it('drops a stale claim pointing past the end of the list', () => {
    expect(autoOpen(['USER.md'], 5, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });

  // The claim survives a repeat reference to the file already in the assistant's
  // own split — otherwise the next reference would take a second slot instead of
  // recycling, and the user's pinned file would be the one squeezed out.
  it('keeps an existing claim when the assistant re-opens the file it already showed', () => {
    expect(autoOpen(['USER.md', 'A.md'], 1, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });

  // A negative claim is nonsense but assigning at it would corrupt the array
  // silently rather than fail; treat it as no claim at all.
  it('ignores a negative claim instead of writing outside the list', () => {
    expect(autoOpen(['USER.md'], -1, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });

  // Same vanishing-descriptor hazard as the Files pane rules: three paths
  // serialize to a `?pane=` value that parses back to null.
  it('never grows past the hard split cap even when told a larger maximum', () => {
    expect(autoOpen(['X.md', 'Y.md'], null, 'A.md', 3)).toEqual({
      paths: ['X.md', 'Y.md'],
      autoIndex: null
    });
  });

  it('leaves an occupied pane untouched when the width allows no split', () => {
    expect(autoOpen(['USER.md'], 0, 'A.md', 0)).toEqual({
      paths: ['USER.md'],
      autoIndex: null
    });
  });
});

describe('clearAuto', () => {
  it('releases the claim when the user opens into that split', () => {
    expect(clearAuto(1, 1)).toBeNull();
  });

  it('keeps the claim when the user opens into a different split', () => {
    expect(clearAuto(1, 0)).toBe(1);
  });

  it('tolerates there being no claim', () => {
    expect(clearAuto(null, 0)).toBeNull();
  });

  // Split 0 is a real index, not an absent claim — a truthiness check here
  // would leak the claim into the split the user just took over.
  it('treats a claim on split 0 like any other', () => {
    expect(clearAuto(0, 0)).toBeNull();
    expect(clearAuto(0, 1)).toBe(0);
  });
});

describe('shiftAuto', () => {
  it('drops the claim when the claimed split is the one removed', () => {
    expect(shiftAuto(0, 0)).toBeNull();
    expect(shiftAuto(1, 1)).toBeNull();
  });

  it('decrements a claim that sat after the removed split', () => {
    expect(shiftAuto(1, 0)).toBe(0);
  });

  it('leaves a claim that sat before the removed split alone', () => {
    expect(shiftAuto(0, 1)).toBe(0);
  });

  it('tolerates there being no claim', () => {
    expect(shiftAuto(null, 0)).toBeNull();
  });

  // `dropVanished` takes a path, so a call site naturally sources the index
  // from `indexOf`, which is -1 when the file was not open at all. Nothing was
  // removed, so nothing renumbered.
  it('treats a removal that did not happen as no change', () => {
    expect(shiftAuto(1, -1)).toBe(1);
    expect(shiftAuto(0, -1)).toBe(0);
  });
});

// The claim is an INDEX, and both removal paths renumber the list. These build
// the sequence through the real `closeSplit` / `dropVanished` rather than
// hand-written indices, because the bug was precisely that the index the
// caller still holds no longer means what it meant when it was issued.
describe('claim survival across removals', () => {
  it('never evicts the user’s file after the assistant’s own split is closed', () => {
    const opened = autoOpen([], null, 'ASSIST.md', 2);
    expect(opened).toEqual({ paths: ['ASSIST.md'], autoIndex: 0 });

    const withUser = openAsSecond(opened.paths, 'USER.md', 2);
    const claim = clearAuto(opened.autoIndex, 1);
    expect(withUser).toEqual(['ASSIST.md', 'USER.md']);
    expect(claim).toBe(0);

    // The user closes the assistant's split. USER.md slides into index 0.
    const closed = closeSplit(withUser, 0);
    expect(closed).toEqual(['USER.md']);

    // Without the re-map the claim still says 0 — which is now USER.md.
    expect(autoOpen(closed, shiftAuto(claim, 0), 'NEW.md', 2)).toEqual({
      paths: ['USER.md', 'NEW.md'],
      autoIndex: 1
    });
  });

  it('never evicts the user’s file after the assistant’s file vanishes', () => {
    const paths = ['ASSIST.md', 'USER.md'];
    const claim = 0;
    const dropped = dropVanished(paths, 'ASSIST.md');
    expect(dropped).toEqual(['USER.md']);

    expect(autoOpen(dropped, shiftAuto(claim, paths.indexOf('ASSIST.md')), 'NEW.md', 2)).toEqual({
      paths: ['USER.md', 'NEW.md'],
      autoIndex: 1
    });
  });

  it('keeps recycling its own split when a split below it is removed', () => {
    const paths = ['USER.md', 'ASSIST.md'];
    const claim = 1;
    const closed = closeSplit(paths, 0);
    expect(closed).toEqual(['ASSIST.md']);

    // The assistant's file is now index 0, so the next reference replaces it
    // rather than taking the free slot beside it.
    expect(autoOpen(closed, shiftAuto(claim, 0), 'NEW.md', 2)).toEqual({
      paths: ['NEW.md'],
      autoIndex: 0
    });
  });

  it('leaves the claim alone when an unrelated split above it is removed', () => {
    const paths = ['ASSIST.md', 'USER.md'];
    const closed = closeSplit(paths, 1);
    expect(autoOpen(closed, shiftAuto(0, 1), 'NEW.md', 2)).toEqual({
      paths: ['NEW.md'],
      autoIndex: 0
    });
  });
});
