/**
 * Persisted pane-row layouts, one per pane COUNT, plus the Files pane's
 * internal tree/splits ratio. Same guarded-storage posture as before: a
 * storage failure (SSR, private mode) degrades to defaults, never an error.
 *
 * Keyed by count because going from two columns to three and back must not
 * lose either arrangement. The count is unambiguous — nothing is ever
 * hidden-but-mounted, so requested, mounted and visible panes are one set.
 */
const LAYOUT_PREFIX = 'valea.pane-split.';
const FILES_KEY = 'valea.files-split';
const FILES_DEFAULT = 40;
const FILES_MIN = 20;
const FILES_MAX = 70;

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
