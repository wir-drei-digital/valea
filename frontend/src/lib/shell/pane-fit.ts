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
export const SPLIT_MIN = 300;

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
