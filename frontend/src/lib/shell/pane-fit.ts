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
 * only clears past 2500px. Since the Files pane's ＋ Split control was removed,
 * there is no other route to a second split, so the capability was simply
 * unreachable on a laptop. At 240 the same arrangement wants 720px, which the
 * PRIMARY pane clears on a 1440px screen. 240 is narrow, but it is a real
 * reading column against Valea's 596px prose measure — the arrangement
 * degrades instead of being refused.
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

/** Drops panes from the right until the rest fit. Callers keep the full list in memory. */
export function truncateToFit(
  panes: PaneDescriptor[],
  windowWidth: number,
  navVisible: boolean
): PaneDescriptor[] {
  return panes.slice(0, panesThatFit(windowWidth, navVisible));
}
