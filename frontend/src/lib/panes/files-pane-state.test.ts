import { describe, expect, it } from 'vitest';
import {
  TAB_CAP,
  activateTab,
  canOpenInNewTab,
  closeTab,
  closeTabPath,
  compareTarget,
  openInActiveTab,
  openInNewTab,
  resolveTabs,
  type TabState
} from './files-pane-state';

/** Reads as the wire form does: paths, which one is showing, what is beside it. */
function tabs(paths: string[], active = 0, compare: number | null = null): TabState {
  return { paths, active, compare };
}

const six = ['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'];

describe('resolveTabs', () => {
  it('keeps a valid triple as it is', () => {
    expect(resolveTabs(['a.md', 'b.md'], 1, 0)).toEqual(tabs(['a.md', 'b.md'], 1, 0));
  });

  // A repeated path is a duplicate `{#each}` key, which Svelte throws on during
  // render — the whole app blanks, no nav, no bar, no error page.
  it('dedupes, because a duplicate path is a render throw', () => {
    expect(resolveTabs(['a.md', 'b.md', 'a.md'], 0, null).paths).toEqual(['a.md', 'b.md']);
  });

  it('truncates past the cap rather than refusing the whole list', () => {
    expect(resolveTabs([...six, 'g.md', 'h.md'], 0, null).paths).toEqual(six);
  });

  it('clamps an out-of-range active index to the first tab', () => {
    expect(resolveTabs(['a.md', 'b.md'], 9, null).active).toBe(0);
    expect(resolveTabs(['a.md', 'b.md'], -1, null).active).toBe(0);
    expect(resolveTabs([], 3, null).active).toBe(0);
  });

  it('drops a compare that cannot be honoured', () => {
    expect(resolveTabs(['a.md', 'b.md'], 0, 9).compare).toBeNull();
    expect(resolveTabs(['a.md', 'b.md'], 1, 1).compare).toBeNull();
    expect(resolveTabs(['a.md'], 0, 1).compare).toBeNull();
    expect(resolveTabs(['a.md', 'b.md'], 0, -1).compare).toBeNull();
  });

  it('never hands back the array it was given', () => {
    const paths = ['a.md'];
    expect(resolveTabs(paths, 0, null).paths).not.toBe(paths);
  });
});

describe('openInActiveTab', () => {
  it('opens the first tab in an empty pane', () => {
    expect(openInActiveTab(tabs([]), 'a.md')).toEqual(tabs(['a.md']));
  });

  // The tree drives the OPEN TAB — this is the behaviour the tab model implies,
  // and it is what makes browsing cost no tabs at all.
  it('replaces the active tab’s file, leaving every other tab alone', () => {
    expect(openInActiveTab(tabs(['a.md', 'b.md', 'c.md'], 1), 'z.md')).toEqual(
      tabs(['a.md', 'z.md', 'c.md'], 1)
    );
  });

  it('activates an already-open file rather than opening it twice', () => {
    expect(openInActiveTab(tabs(['a.md', 'b.md', 'c.md'], 0), 'c.md')).toEqual(
      tabs(['a.md', 'b.md', 'c.md'], 2)
    );
  });

  it('is a no-op on the file already showing', () => {
    expect(openInActiveTab(tabs(['a.md', 'b.md'], 1), 'b.md')).toEqual(tabs(['a.md', 'b.md'], 1));
  });

  // Width used to govern this: a pane too narrow for two splits shed one on
  // every tree click. A tab costs no width, so nothing here can drop a file.
  it('never shortens the strip, however many tabs are open', () => {
    expect(openInActiveTab(tabs(six, 3), 'z.md').paths).toHaveLength(TAB_CAP);
  });

  it('leaves compare on, now showing the new file beside the same partner', () => {
    expect(openInActiveTab(tabs(['a.md', 'b.md'], 0, 1), 'z.md')).toEqual(
      tabs(['z.md', 'b.md'], 0, 1)
    );
  });
});

describe('openInNewTab', () => {
  it('appends a tab and shows it', () => {
    expect(openInNewTab(tabs(['a.md'], 0), 'b.md')).toEqual(tabs(['a.md', 'b.md'], 1));
  });

  it('opens the first tab in an empty pane', () => {
    expect(openInNewTab(tabs([]), 'a.md')).toEqual(tabs(['a.md']));
  });

  it('activates an already-open file rather than opening it twice', () => {
    expect(openInNewTab(tabs(['a.md', 'b.md'], 0), 'b.md')).toEqual(tabs(['a.md', 'b.md'], 1));
  });

  // The cap rule: a seventh tab replaces the OLDEST INACTIVE one — lowest
  // index, which is open order. There is no scrolling strip to hold a seventh.
  it('replaces the oldest inactive tab at the cap', () => {
    expect(openInNewTab(tabs(six, 3), 'g.md')).toEqual(
      tabs(['g.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'], 0)
    );
  });

  it('never evicts the tab you are reading', () => {
    expect(openInNewTab(tabs(six, 0), 'g.md')).toEqual(
      tabs(['a.md', 'g.md', 'c.md', 'd.md', 'e.md', 'f.md'], 1)
    );
  });

  // Replacing IN PLACE is what lets the assistant's auto-open claim survive an
  // eviction without every caller having to re-map it — see `auto-open.ts`.
  it('renumbers nothing: every surviving tab keeps its index', () => {
    const after = openInNewTab(tabs(six, 5), 'g.md');
    expect(after.paths).toHaveLength(TAB_CAP);
    expect(after.paths[5]).toBe('f.md');
    expect(after.paths.indexOf('b.md')).toBe(1);
  });

  it('keeps compare pointing at the same file when it was not the one evicted', () => {
    expect(openInNewTab(tabs(six, 5, 4), 'g.md').compare).toBe(4);
  });
});

describe('canOpenInNewTab', () => {
  // Width is no longer a reason for anything here: a tab takes none. The tree
  // row's affordance disables at the cap and says why, rather than silently
  // destroying a tab the user opened from a hover control.
  it('is true below the cap', () => {
    expect(canOpenInNewTab(tabs([]))).toBe(true);
    expect(canOpenInNewTab(tabs(six.slice(0, 5), 0))).toBe(true);
  });

  it('is false at the cap', () => {
    expect(canOpenInNewTab(tabs(six, 0))).toBe(false);
  });
});

describe('activateTab', () => {
  it('shows the tab', () => {
    expect(activateTab(tabs(['a.md', 'b.md'], 0), 1)).toEqual(tabs(['a.md', 'b.md'], 1));
  });

  it('ignores an out-of-range index', () => {
    const state = tabs(['a.md', 'b.md'], 0);
    expect(activateTab(state, 5)).toBe(state);
    expect(activateTab(state, -1)).toBe(state);
  });

  // Turning a comparison off because you clicked one half of it is a control
  // undoing itself; swapping the columns is what the click actually meant.
  it('swaps the columns when the compare partner is the tab clicked', () => {
    expect(activateTab(tabs(['a.md', 'b.md'], 0, 1), 1)).toEqual(tabs(['a.md', 'b.md'], 1, 0));
  });
});

describe('closeTab', () => {
  it('removes the tab', () => {
    expect(closeTab(tabs(['a.md', 'b.md'], 0), 1)).toEqual(tabs(['a.md']));
  });

  it('leaves a tree-only pane when the last tab closes', () => {
    expect(closeTab(tabs(['a.md'], 0), 0)).toEqual(tabs([]));
  });

  it('returns the same state for an out-of-range index', () => {
    const state = tabs(['a.md'], 0);
    expect(closeTab(state, 3)).toBe(state);
    expect(closeTab(state, -1)).toBe(state);
  });

  it('activates the left neighbour when the active tab closes', () => {
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 2), 2)).toEqual(tabs(['a.md', 'b.md'], 1));
  });

  it('activates the right neighbour when the FIRST tab closes', () => {
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 0), 0)).toEqual(tabs(['b.md', 'c.md'], 0));
  });

  // The claim-shaped bug, in the other direction: an index that does not move
  // with the list stops naming the file it named.
  it('renumbers the active tab when a tab BEFORE it closes', () => {
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 2), 0)).toEqual(tabs(['b.md', 'c.md'], 1));
  });

  it('leaves the active tab alone when a tab AFTER it closes', () => {
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 0), 2)).toEqual(tabs(['a.md', 'b.md'], 0));
  });

  it('renumbers compare, and drops it when its own tab closes', () => {
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 2, 0), 1)).toEqual(tabs(['a.md', 'c.md'], 1, 0));
    expect(closeTab(tabs(['a.md', 'b.md', 'c.md'], 2, 0), 0)).toEqual(tabs(['b.md', 'c.md'], 1));
  });

  it('never mutates the list it was given', () => {
    const state = tabs(['a.md', 'b.md'], 0);
    closeTab(state, 1);
    expect(state.paths).toEqual(['a.md', 'b.md']);
  });
});

describe('closeTabPath', () => {
  it('closes by file', () => {
    expect(closeTabPath(tabs(['a.md', 'b.md'], 1), 'a.md')).toEqual(tabs(['b.md'], 0));
  });

  it('returns the same state for a file that is not open', () => {
    const state = tabs(['a.md'], 0);
    expect(closeTabPath(state, 'z.md')).toBe(state);
  });
});

describe('compareTarget', () => {
  it('is the previously active tab', () => {
    expect(compareTarget(tabs(['a.md', 'b.md', 'c.md'], 2), 0)).toBe(0);
  });

  // History is absent after a reload, and the control is visibly available —
  // refusing there would be a dead button with no reason to give.
  it('falls back to the left neighbour without history', () => {
    expect(compareTarget(tabs(['a.md', 'b.md', 'c.md'], 2), null)).toBe(1);
  });

  it('falls back to the RIGHT neighbour when the first tab is active', () => {
    expect(compareTarget(tabs(['a.md', 'b.md'], 0), null)).toBe(1);
  });

  it('ignores a stale previous index', () => {
    expect(compareTarget(tabs(['a.md', 'b.md'], 1), 9)).toBe(0);
    expect(compareTarget(tabs(['a.md', 'b.md'], 1), 1)).toBe(0);
  });

  it('is null with fewer than two tabs', () => {
    expect(compareTarget(tabs(['a.md'], 0), null)).toBeNull();
    expect(compareTarget(tabs([]), null)).toBeNull();
  });
});
