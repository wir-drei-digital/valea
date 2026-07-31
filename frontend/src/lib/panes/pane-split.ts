/**
 * Persisted pane-row layouts, one per pane COUNT, plus the Files pane's
 * internal tree/splits ratio. Same guarded-storage posture as before: a
 * storage failure (SSR, private mode) degrades to defaults, never an error.
 *
 * Keyed by count because going from two columns to three and back must not
 * lose either arrangement. The count is unambiguous — nothing is ever
 * hidden-but-mounted, so requested, mounted and visible panes are one set.
 */
import type { PaneDescriptor } from './pane-route';

const LAYOUT_PREFIX = 'valea.pane-split.';
const FILES_KEY = 'valea.files-split';
const FILES_DEFAULT = 40;
const FILES_MIN = 20;
const FILES_MAX = 70;

/**
 * How much wider the primary starts than one side pane. 1.5 is chosen so the
 * two-pane row still opens at the 60/40 this app shipped with — the storage
 * key changed shape (it is per-count now), so every user meets the default
 * once more and should meet the familiar one.
 */
const PRIMARY_WEIGHT = 1.5;

function clampFiles(pct: number): number {
  return Math.min(FILES_MAX, Math.max(FILES_MIN, Math.round(pct)));
}

export function loadPaneLayout(count: number): number[] | null {
  try {
    const raw = localStorage.getItem(LAYOUT_PREFIX + count);
    if (raw === null) return null;
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length !== count) return null;
    if (!parsed.every((n) => typeof n === 'number' && Number.isFinite(n))) return null;
    return parsed as number[];
  } catch {
    return null;
  }
}

/**
 * The layout a row of `count` panes opens at when nothing is stored for that
 * count. `loadPaneLayout` returns null rather than a default because the
 * arithmetic is the CALLER's: side panes share the row evenly and the primary
 * takes `PRIMARY_WEIGHT` shares of it. Percentages, summing to exactly 100 —
 * the remainder lands on the primary, which is the one pane wide enough to
 * absorb a rounding point without approaching its minimum.
 */
export function defaultPaneLayout(count: number): number[] {
  if (!Number.isFinite(count) || count <= 1) return [100];
  const sides = Math.trunc(count) - 1;
  const side = Math.round(100 / (PRIMARY_WEIGHT + sides));
  return [100 - side * sides, ...Array<number>(sides).fill(side)];
}

/**
 * The layout a row of `panes` (plus the primary) should open at: the
 * arrangement the user dragged for this pane COUNT if there is one, else the
 * count's default.
 *
 * It takes the pane LIST rather than a count, and that is load-bearing rather
 * than a convenience. Only `panes.length` is read, but in `PaneHost` this is a
 * `$derived`, and a derived over the COUNT alone goes stale: dragging the
 * divider persists a new layout WITHOUT changing the count, so the count's
 * value never changes, Svelte never propagates it (a derived's default
 * `equals` is `===`, and `2 === 2`), and the memoized layout keeps serving the
 * pre-drag numbers.
 *
 * That staleness is not cosmetic, because paneforge recomputes the whole row
 * from every pane's CURRENT `defaultSize` whenever a pane registers or
 * unregisters — and a descriptor change does exactly that, since side panes
 * are keyed by their serialized descriptor. It then fires `onLayout`, so the
 * stale numbers are written straight back over the drag. Reading the LIST
 * makes the layout re-read storage on every reassignment of the prop, which
 * strictly includes every remount, and a fresh array always propagates.
 */
export function paneRowLayout(panes: PaneDescriptor[]): number[] {
  const count = panes.length + 1;
  return loadPaneLayout(count) ?? defaultPaneLayout(count);
}

export function savePaneLayout(count: number, layout: number[]): void {
  if (layout.length !== count) return;
  if (!layout.every((n) => Number.isFinite(n))) return;
  try {
    localStorage.setItem(LAYOUT_PREFIX + count, JSON.stringify(layout));
  } catch {
    // best-effort persistence only
  }
}

export function loadFilesSplit(): number {
  try {
    const raw = localStorage.getItem(FILES_KEY);
    if (raw === null) return FILES_DEFAULT;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? clampFiles(parsed) : FILES_DEFAULT;
  } catch {
    return FILES_DEFAULT;
  }
}

export function saveFilesSplit(pct: number): void {
  try {
    localStorage.setItem(FILES_KEY, String(clampFiles(pct)));
  } catch {
    // best-effort persistence only
  }
}
