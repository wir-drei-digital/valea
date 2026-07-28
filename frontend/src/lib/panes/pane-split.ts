/**
 * Persisted split ratio for PaneHost (percent width of the PRIMARY pane).
 * Same localStorage pattern as `tree-state.svelte.ts` — storage failures
 * (SSR, private mode, disabled storage) degrade to the default silently.
 */
const KEY = 'valea.pane-split';
const DEFAULT = 60;
const MIN = 30;
const MAX = 70;

function clamp(pct: number): number {
  return Math.min(MAX, Math.max(MIN, Math.round(pct)));
}

export function loadPaneSplit(): number {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw === null) return DEFAULT;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? clamp(parsed) : DEFAULT;
  } catch {
    return DEFAULT;
  }
}

export function savePaneSplit(pct: number): void {
  try {
    localStorage.setItem(KEY, String(clamp(pct)));
  } catch {
    // best-effort persistence only
  }
}
