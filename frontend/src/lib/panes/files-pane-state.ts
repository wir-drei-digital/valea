/**
 * Pure rules for what a Files pane has open. The pane owns this state
 * privately — nothing outside it can observe the relationship between the tree
 * and the content, which is the whole point of the self-contained-pane design.
 *
 * These used to be SPLIT rules, where every open competed for horizontal width:
 * two files needed a ~1439px window, `SPLIT_MIN` had to come down from 300 to
 * 240 to reach a laptop at all, and a pane a tool chip created could still
 * starve a file to twenty pixels. TABS COST NO WIDTH. One file gets the whole
 * content area at any pane size, so nothing in this module consults a width any
 * more — the only surviving width rules are `treeFits` (the navigator beside a
 * file) and the compare escape, which genuinely does put two files side by side.
 *
 * A `TabState` is the pane's whole content: the open tabs in strip order,
 * which one is showing, and — only while compare is on — which other one is
 * showing beside it. Every function here returns a FRESH state; nothing is
 * mutated in place, because these lists end up inside descriptors that
 * `PaneHost` re-derives its row layout from.
 *
 * The caps: at most `TAB_CAP` tabs, no scrolling strip and no overflow chrome.
 */
export const TAB_CAP = 6;

export type TabState = {
  /** Open tabs, in strip order. At most `TAB_CAP`, never duplicated. */
  paths: string[];
  /** Index of the showing tab. Always in range, always 0 when there are none. */
  active: number;
  /**
   * The compare escape: the index of the tab showing BESIDE the active one,
   * or `null` when compare is off. `active` is the left column.
   */
  compare: number | null;
};

/**
 * Any (paths, active, compare) triple, made valid.
 *
 * Every entry point goes through this — the URL codec, the tree, the strip —
 * so "what is a legal tab state" is written once. It repairs rather than
 * refuses: a hand-written URL naming nine files is still describing eight
 * perfectly good subjects, and an out-of-range active index is still a valid
 * list of tabs. What it will not do is let an invalid state through, because
 * both of the things that would produce are severe: a duplicated path is a
 * duplicate `{#each}` key, which Svelte throws on during render and blanks the
 * whole app; and an out-of-range `active` renders nothing at all.
 */
export function resolveTabs(
  paths: readonly string[],
  active: number,
  compare: number | null
): TabState {
  const unique = [...new Set(paths)].slice(0, TAB_CAP);
  // Clamped to 0 rather than to the last tab: an index past the end carries no
  // information about which tab was meant, and the first is the one place a
  // reader can predict.
  const at = Number.isInteger(active) && active >= 0 && active < unique.length ? active : 0;
  const beside =
    compare !== null &&
    Number.isInteger(compare) &&
    compare >= 0 &&
    compare < unique.length &&
    compare !== at &&
    unique.length >= 2
      ? compare
      : null;
  return { paths: unique, active: at, compare: beside };
}

/**
 * A tree click: the tree drives the OPEN TAB, so the active tab's file is
 * replaced. With no tabs at all it opens the first one.
 *
 * Clicking a file that is already open activates its tab instead of opening a
 * second copy of it — the alternative is a duplicate path, which is the
 * duplicate-key render crash described above.
 */
export function openInActiveTab(state: TabState, path: string): TabState {
  const at = state.paths.indexOf(path);
  if (at !== -1) return activateTab(state, at);
  if (state.paths.length === 0) return resolveTabs([path], 0, null);
  const paths = state.paths.map((p, i) => (i === state.active ? path : p));
  return resolveTabs(paths, state.active, state.compare);
}

/**
 * "Open in a new tab" — the tree row's hover affordance, and where a pending
 * empty tab materialises when a file is picked for it.
 *
 * AT THE CAP IT REPLACES THE OLDEST INACTIVE TAB, never the active one: the
 * strip holds six and there is no scrolling or overflow chrome for a seventh.
 * "Oldest" is the lowest index, which is open order — tabs append and are
 * never reordered.
 *
 * Replacing IN PLACE rather than dropping-and-appending is deliberate. It
 * keeps every other tab's index still meaning what it meant, so the
 * assistant's auto-open claim (`auto-open.ts`) does not have to be re-mapped
 * by a caller that has no idea a tab was evicted; the claim on the evicted
 * slot fails closed by itself, because the file it was made for is no longer
 * in it.
 *
 * The two callers are gated differently ON PURPOSE, and `canOpenInNewTab` is
 * the difference: the tree row disables itself at the cap and says why, rather
 * than silently destroying a tab you opened from a control that is only a
 * hover affordance on a row whose plain click already does something else.
 * Pressing ＋ and then picking a file is an unambiguous request for a new tab,
 * so it is honoured at the cost of the oldest inactive one.
 */
export function openInNewTab(state: TabState, path: string): TabState {
  const at = state.paths.indexOf(path);
  if (at !== -1) return activateTab(state, at);
  if (state.paths.length < TAB_CAP) {
    return resolveTabs([...state.paths, path], state.paths.length, state.compare);
  }
  const evicted = state.paths.findIndex((_, i) => i !== state.active);
  // Unreachable while `TAB_CAP >= 2` (one active tab leaves five inactive), but
  // a cap of 1 would leave nothing to evict and the click has to mean
  // something — so it falls back to the active tab, which is what
  // `openInActiveTab` would have done.
  const target = evicted === -1 ? state.active : evicted;
  const paths = state.paths.map((p, i) => (i === target ? path : p));
  return resolveTabs(paths, target, state.compare);
}

/**
 * Whether the tree row's "Open in a new tab" can act. Width is deliberately
 * NOT a reason any more — a tab takes none. The cap is the only one left.
 */
export function canOpenInNewTab(state: TabState): boolean {
  return state.paths.length < TAB_CAP;
}

/**
 * Show a tab. Clicking the tab currently showing BESIDE the active one (the
 * compare partner) swaps the two columns rather than dropping compare: the
 * user asked to look at that file, and turning a comparison off because you
 * clicked one half of it is a control undoing itself.
 */
export function activateTab(state: TabState, index: number): TabState {
  if (index < 0 || index >= state.paths.length || index === state.active) return state;
  const compare = state.compare === index ? state.active : state.compare;
  return resolveTabs(state.paths, index, compare);
}

/**
 * Close one tab. Closing the ACTIVE tab activates its left neighbour, or its
 * right if it was the first — the neighbour is where you were reading a moment
 * ago, which is the least surprising place to land.
 *
 * An out-of-range index returns the SAME state object, so a caller can tell
 * "nothing happened" from "something did" without a second flag. Everything
 * else allocates.
 */
export function closeTab(state: TabState, index: number): TabState {
  if (index < 0 || index >= state.paths.length) return state;
  const paths = state.paths.filter((_, i) => i !== index);
  // The left neighbour after removal sits at `index - 1`; the right one slid
  // down into `index`, which is 0 when the first tab was the one closed.
  const active =
    state.active === index
      ? Math.max(0, index - 1)
      : state.active > index
        ? state.active - 1
        : state.active;
  const compare =
    state.compare === null || state.compare === index
      ? null
      : state.compare > index
        ? state.compare - 1
        : state.compare;
  return resolveTabs(paths, active, compare);
}

/** `closeTab` for a caller that knows the file rather than the slot. */
export function closeTabPath(state: TabState, path: string): TabState {
  return closeTab(state, state.paths.indexOf(path));
}

/**
 * Which tab the compare escape puts beside the active one when it is switched
 * on: the PREVIOUSLY active tab, which is what "compare these two" means when
 * you have just switched between them.
 *
 * `previous` is history and history can be absent — a reload, a fresh pane, a
 * tab that has since closed. Rather than refuse a control the user can see is
 * available, it falls back to the neighbour: the tab on the left, or the one
 * on the right when the active tab is the first. `null` only when there is
 * genuinely no second tab.
 */
export function compareTarget(state: TabState, previous: number | null): number | null {
  if (state.paths.length < 2) return null;
  if (
    previous !== null &&
    previous >= 0 &&
    previous < state.paths.length &&
    previous !== state.active
  ) {
    return previous;
  }
  return state.active > 0 ? state.active - 1 : 1;
}
