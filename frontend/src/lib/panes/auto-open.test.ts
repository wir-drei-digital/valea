import { describe, expect, it } from 'vitest';
import { autoOpen, clearAuto } from './auto-open';

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
