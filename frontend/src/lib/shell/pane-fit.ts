/**
 * Width arithmetic for the pane row. Consulted ONLY when a pane or split is
 * added or restored — never on resize. See the spec's "Width behaviour":
 * continuous auto-hide would mean unmounting a mounted `ChatView`, which
 * disposes its `AgentSessionStore` and drops the composer's draft.
 */
import { PANE_CAP, type PaneDescriptor } from '$lib/panes/pane-route';

export const NAV_W = 236;
export const PRIMARY_MIN = 380;
export const PANE_MIN = 300;
export const TREE_W = 240;
/**
 * How narrow ONE file split may be. Deliberately smaller than `PANE_MIN`: a
 * pane is a whole surface with its own header and navigator, a split is just a
 * reading column.
 *
 * It was 300, which quietly made two files side by side a large-monitor
 * feature — a tree plus two splits wanted 840px of PANE, which a side pane
 * only clears at a 2339px window. Since the Files pane's ＋ Split control was
 * removed, there is no other route to a second split, so the capability was
 * simply unreachable on a laptop. At 240 the same arrangement wants 720px,
 * which the PRIMARY pane clears at 1439px. 240 is narrow, but it is a real
 * reading column against Valea's 596px prose measure — the arrangement
 * degrades instead of being refused.
 *
 * Every window figure in this file and in `files-pane-state.ts` / `auto-open.ts`
 * is derived the same way, and it is written out here once so the rest can be
 * checked: `PaneHost`'s row is `window - NAV_W` wide and spends 3px on each
 * `PaneResizer`, so a two-pane row shares `window - 239` at
 * `defaultPaneLayout(2)` = 60/40. A SIDE pane is therefore
 * `0.4 * (window - 239)` and the PRIMARY `0.6 * (window - 239)`; invert either
 * for the window a given pane width needs. 840px of side pane wants
 * `840 / 0.4 + 239 = 2339`; 720px of primary wants `720 / 0.6 + 239 = 1439`.
 */
export const SPLIT_MIN = 240;

const SPLIT_CAP = 2;

export function panesThatFit(windowWidth: number, navVisible: boolean): number {
  const spare = windowWidth - (navVisible ? NAV_W : 0) - PRIMARY_MIN;
  if (spare < 0) return 0;
  return Math.min(PANE_CAP, Math.floor(spare / PANE_MIN));
}

export function splitsThatFit(paneWidth: number, treeVisible: boolean): number {
  const spare = paneWidth - (treeVisible ? TREE_W : 0);
  if (spare < 0) return 0;
  return Math.min(SPLIT_CAP, Math.floor(spare / SPLIT_MIN));
}

/**
 * Whether a Files pane can afford to render its tree — the one width rule that
 * IS consulted continuously, because the thing it protects is already mounted.
 *
 * The tree is a fixed 240px `shrink-0` column, so it takes its width out of the
 * pane before the file column sees any and never yields a pixel of it back. A
 * pane too narrow for both therefore does not render a cramped file, it renders
 * an invisible one: an assistant-opened Files pane at a 900px window is 260px
 * wide, and 260 - 240 leaves the document 20px. It mounts, it fetches, it is
 * simply not there. The row cost a pane slot to show nothing.
 *
 * Two answers are deliberately YES:
 *   - `filesOpen === 0` — there is no file to starve, and a Files pane showing
 *     neither tree nor file is the empty screen the earlier blanket auto-hide
 *     proposal was rejected for. An empty pane is all navigator.
 *   - `paneWidth <= 0` — not measured yet rather than infinitely narrow.
 *     `bind:clientWidth` reads 0 until the first ResizeObserver delivery, and
 *     answering NO there would hide the tree of every Files pane for a frame.
 *
 * This is safe to re-evaluate on resize in a way `panesThatFit` is not: hiding
 * the tree unmounts a navigator whose open/closed state lives in a store
 * (`treeOpenState`), not a live `ChatView` with a session channel and an unsent
 * draft. See this file's header for why the pane-level rule cannot do the same.
 */
export function treeFits(paneWidth: number, filesOpen: number): boolean {
  if (filesOpen === 0 || paneWidth <= 0) return true;
  return splitsThatFit(paneWidth, true) >= 1;
}

/** Drops panes from the right until the rest fit. Callers keep the full list in memory. */
export function truncateToFit(
  panes: PaneDescriptor[],
  windowWidth: number,
  navVisible: boolean
): PaneDescriptor[] {
  return panes.slice(0, panesThatFit(windowWidth, navVisible));
}
