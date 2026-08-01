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
/**
 * How wide a Files pane's tree opens, before the user drags it. It is a
 * DEFAULT now rather than the constant it used to be — the tree is resizable,
 * like every other column in this feature — so nothing may assume it is the
 * width on screen; `clampTreeWidth` answers that.
 *
 * 280 rather than the 240 it shipped at: at 240 a nested folder plus a
 * filename truncated on nearly every real ICM row, which is the one thing a
 * navigator must not do.
 */
export const TREE_W = 280;
/** The narrowest a dragged tree may get before it stops being a navigator. */
export const TREE_MIN = 200;
/** And the widest, so it can never become the pane's second reading surface. */
export const TREE_MAX = 480;
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

/**
 * `treeWidth` is the tree's width IN PIXELS, or 0 when it is not rendered — not
 * a boolean, because the tree is draggable and `TREE_W` is only where it
 * starts. Callers pass what is on screen (`clampTreeWidth`), so the arithmetic
 * always reasons about the column the user can actually see.
 */
export function splitsThatFit(paneWidth: number, treeWidth: number): number {
  const spare = paneWidth - Math.max(0, treeWidth);
  if (spare < 0) return 0;
  return Math.min(SPLIT_CAP, Math.floor(spare / SPLIT_MIN));
}

/**
 * The tree width a pane will actually render, given the width the user dragged
 * to and how much pane there is.
 *
 * The ceiling is what makes dragging safe: the tree can never take so much of
 * the pane that the file drops below `SPLIT_MIN`, so a drag can never push the
 * tree past the point where `treeFits` would hide it — a control that made
 * itself disappear. It is also what keeps a stored width HONEST across pane
 * sizes: narrowing the pane squeezes the tree toward `TREE_MIN` rather than
 * hiding it, and widening it again restores the full stored width, because the
 * preference is never rewritten by this.
 *
 * An unmeasured pane (`paneWidth <= 0`) has no ceiling to give, so only the
 * absolute bounds apply — the same "not measured yet rather than infinitely
 * narrow" reading `treeFits` takes.
 */
export function clampTreeWidth(width: number, paneWidth: number): number {
  if (!Number.isFinite(width)) return TREE_W;
  const room = paneWidth > 0 ? paneWidth - SPLIT_MIN : TREE_MAX;
  const ceiling = Math.max(TREE_MIN, Math.min(TREE_MAX, room));
  return Math.round(Math.max(TREE_MIN, Math.min(ceiling, width)));
}

/**
 * Whether a Files pane can afford to render its tree — the one width rule that
 * IS consulted continuously, because the thing it protects is already mounted.
 *
 * The tree is a `shrink-0` column, so it takes its width out of the pane before
 * the file column sees any and never yields a pixel of it back. A pane too
 * narrow for both therefore does not render a cramped file, it renders an
 * invisible one: an assistant-opened Files pane at a 900px window is 260px
 * wide, and 260 - 240 leaves the document 20px. It mounts, it fetches, it is
 * simply not there. The row cost a pane slot to show nothing.
 *
 * `treeWidth` is what the tree would RENDER at, which callers get from
 * `clampTreeWidth` — so the answer flips at `TREE_MIN + SPLIT_MIN` (440px)
 * however wide the user dragged the tree, rather than at whatever they last
 * left it. Dragging is not a way to lose the navigator.
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
export function treeFits(paneWidth: number, filesOpen: number, treeWidth: number): boolean {
  if (filesOpen === 0 || paneWidth <= 0) return true;
  return splitsThatFit(paneWidth, treeWidth) >= 1;
}

/** Drops panes from the right until the rest fit. Callers keep the full list in memory. */
export function truncateToFit(
  panes: PaneDescriptor[],
  windowWidth: number,
  navVisible: boolean
): PaneDescriptor[] {
  return panes.slice(0, panesThatFit(windowWidth, navVisible));
}
