import { describe, expect, it } from 'vitest';
import { autoOpen, clearAuto, shiftAuto, shiftAutoAll } from './auto-open';
import { TAB_CAP, closeTab, openInNewTab, type TabState } from './files-pane-state';
import { dropSubject } from './pane-edit';
import type { PaneDescriptor } from './pane-route';

/** The tab rules take a whole state; these cases only care about the list. */
function tabs(paths: string[], active = 0): TabState {
  return { paths, active, compare: null };
}

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

  // The same rule at the real cap: `openInNewTab` evicts the oldest inactive
  // tab when a PERSON asks for a seventh, and auto-open deliberately does not
  // — an assistant read must never cost a tab the user opened.
  it('does nothing when every one of the six tabs is the user’s', () => {
    const full = ['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'];
    expect(autoOpen(full, null, 'g.md', TAB_CAP)).toEqual({ paths: full, autoIndex: null });
  });

  it('takes a free tab well past the old two-split ceiling', () => {
    expect(autoOpen(['a.md', 'b.md', 'c.md'], null, 'd.md', TAB_CAP)).toEqual({
      paths: ['a.md', 'b.md', 'c.md', 'd.md'],
      autoIndex: 3
    });
  });

  // Rule 3's "do nothing" protects a file the USER placed, and an empty pane
  // has none — so the first file lands whatever the cap says, exactly as it
  // does in `openInActiveTab`. This began as a width case: a split needed
  // 480px of pane, which a side pane did not reach below a 1439px window, so a
  // tool chip opening into an empty Files pane was inert on a 1280-wide
  // screen. Tabs cost no width, but the floor stays — a caller that computes a
  // zero for any other reason must still not swallow the assistant's file.
  it('opens the first file even when the cap allows nothing at all', () => {
    expect(autoOpen([], null, 'A.md', 0)).toEqual({ paths: ['A.md'], autoIndex: 0 });
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

  // The cap is absolute, not merely whatever the caller passed: a list longer
  // than `TAB_CAP` truncates on the way through the codec, so growing one here
  // would silently drop the tab it just added.
  it('never grows past the hard tab cap even when told a larger maximum', () => {
    const full = ['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'];
    expect(autoOpen(full, null, 'g.md', 99)).toEqual({ paths: full, autoIndex: null });
  });

  // The other half of rule 0: the first-file floor is for an EMPTY pane only.
  // Once the user has placed a file, a cap of zero means the assistant does not
  // get a tab — it must never evict what is there.
  it('leaves an occupied pane untouched when the cap allows nothing', () => {
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

  // The vanished-file path takes a PATH, so its call site
  // (`FilesPane.fileVanished`) sources the index from `indexOf`, which is -1
  // when the file was not open at all. Nothing was removed, so nothing
  // renumbered.
  it('treats a removal that did not happen as no change', () => {
    expect(shiftAuto(1, -1)).toBe(1);
    expect(shiftAuto(0, -1)).toBe(0);
  });
});

describe('shiftAutoAll', () => {
  it('leaves the claim alone when nothing was removed', () => {
    expect(shiftAutoAll(1, [])).toBe(1);
  });

  it('applies a single removal exactly as shiftAuto would', () => {
    expect(shiftAutoAll(1, [0])).toBe(0);
    expect(shiftAutoAll(0, [1])).toBe(0);
    expect(shiftAutoAll(1, [1])).toBeNull();
  });

  it('drops the claim when the deleted folder took the claimed split too', () => {
    expect(shiftAutoAll(0, [0, 1])).toBeNull();
    expect(shiftAutoAll(1, [0, 1])).toBeNull();
  });

  it('applies removals highest-index first, whatever order it is given', () => {
    // Ascending would apply `0` first, renumbering the list under the caller's
    // own second index, and read `1` against a list that no longer has one.
    // A three-split list is not reachable today, but the order is the rule.
    expect(shiftAutoAll(2, [0, 1])).toBe(0);
    expect(shiftAutoAll(2, [1, 0])).toBe(0);
  });

  it('tolerates there being no claim, and removals that did not happen', () => {
    expect(shiftAutoAll(null, [0, 1])).toBeNull();
    expect(shiftAutoAll(1, [-1])).toBe(1);
  });

  it('does not mutate the index list it was given', () => {
    const removed = [0, 1];
    shiftAutoAll(1, removed);
    expect(removed).toEqual([0, 1]);
  });
});

// The claim is an INDEX, and both removal paths renumber the list. These build
// the sequence through the real `closeTab` and the real `dropSubject` — the two
// functions that actually renumber `paths` in production — rather than
// hand-written indices, because the bug was precisely that the index the
// caller still holds no longer means what it meant when it was issued.
describe('claim survival across removals', () => {
  it('never evicts the user’s file after the assistant’s own tab is closed', () => {
    const opened = autoOpen([], null, 'ASSIST.md', 2);
    expect(opened).toEqual({ paths: ['ASSIST.md'], autoIndex: 0 });

    const withUser = openInNewTab(tabs(opened.paths), 'USER.md');
    const claim = clearAuto(opened.autoIndex, 1);
    expect(withUser.paths).toEqual(['ASSIST.md', 'USER.md']);
    expect(claim).toBe(0);

    // The user closes the assistant's tab. USER.md slides into index 0.
    const closed = closeTab(withUser, 0);
    expect(closed.paths).toEqual(['USER.md']);

    // Without the re-map the claim still says 0 — which is now USER.md.
    expect(autoOpen(closed.paths, shiftAuto(claim, 0), 'NEW.md', 2)).toEqual({
      paths: ['USER.md', 'NEW.md'],
      autoIndex: 1
    });
  });

  it('never evicts the user’s file after the assistant’s file vanishes', () => {
    // The real sequence: `FilesPane.fileVanished` re-maps the claim off
    // `paths.indexOf(path)` and then hands the subject to the host, whose
    // `PaneContext.onVanished` rewrites the descriptor through `dropSubject`.
    const pane: PaneDescriptor = {
      kind: 'files',
      mountKey: 'life',
      paths: ['ASSIST.md', 'USER.md'],
      active: 0,
      compare: null
    };
    const claim = 0;
    const dropped = dropSubject(pane, 'ASSIST.md');
    expect(dropped).toEqual({
      kind: 'files',
      mountKey: 'life',
      paths: ['USER.md'],
      active: 0,
      compare: null
    });

    const paths = dropped?.kind === 'files' ? dropped.paths : [];
    expect(autoOpen(paths, shiftAuto(claim, pane.paths.indexOf('ASSIST.md')), 'NEW.md', 2)).toEqual({
      paths: ['USER.md', 'NEW.md'],
      autoIndex: 1
    });
  });

  it('keeps recycling its own tab when a tab below it is removed', () => {
    const claim = 1;
    const closed = closeTab(tabs(['USER.md', 'ASSIST.md'], 1), 0);
    expect(closed.paths).toEqual(['ASSIST.md']);

    // The assistant's file is now index 0, so the next reference replaces it
    // rather than taking the free slot beside it.
    expect(autoOpen(closed.paths, shiftAuto(claim, 0), 'NEW.md', 2)).toEqual({
      paths: ['NEW.md'],
      autoIndex: 0
    });
  });

  it('leaves the claim alone when an unrelated tab above it is removed', () => {
    const closed = closeTab(tabs(['ASSIST.md', 'USER.md']), 1);
    expect(autoOpen(closed.paths, shiftAuto(0, 1), 'NEW.md', 2)).toEqual({
      paths: ['NEW.md'],
      autoIndex: 0
    });
  });

  // The one removal that deliberately needs NO `shiftAuto`, recorded so nobody
  // "fixes" it: the cap eviction replaces in place, so every surviving index
  // still names the file it named, and the claim on the evicted slot is
  // refused by the pane's own path check rather than by a shift.
  it('renumbers nothing when a seventh tab evicts the oldest inactive one', () => {
    const full = tabs(['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'], 5);
    const claim = 3;
    const after = openInNewTab(full, 'g.md');
    expect(after.paths[claim]).toBe('d.md');
    expect(autoOpen(after.paths, claim, 'NEW.md', TAB_CAP).paths[claim]).toBe('NEW.md');
  });
});
