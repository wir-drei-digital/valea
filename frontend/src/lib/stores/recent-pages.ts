/**
 * Pure(ish) MRU (most-recently-used) page tracker for the Cmd+K palette
 * (Task C9). "Pure" in the sense of doing no network I/O and having no
 * reactive/store state of its own — the only side effect is reading/writing
 * `localStorage`, guarded (`typeof localStorage === 'undefined'`) so this
 * module is safe to import from anywhere, including a non-browser context
 * (SSR, or this file's own vitest run — see the test file's header comment:
 * this project's tests run with no DOM, so that guard is exercised for
 * real, not just defensively).
 *
 * Persisted as a plain JSON array of paths (most-recent-first) under
 * `localStorage['valea.recent-pages']` — deliberately just paths, not full
 * `{title, mount, snippet}` rows: the palette re-derives a display title
 * from the path itself (see `SearchPalette.svelte`), so a page renamed
 * since its last visit doesn't leave a stale title sitting in storage.
 */

const STORAGE_KEY = 'valea.recent-pages';
const MAX_ENTRIES = 10;

function hasLocalStorage(): boolean {
  return typeof localStorage !== 'undefined';
}

/** Reads the persisted list, tolerating absent/corrupted/wrongly-shaped storage by falling back to empty. */
function readStored(): string[] {
  if (!hasLocalStorage()) return [];

  let raw: string | null;
  try {
    raw = localStorage.getItem(STORAGE_KEY);
  } catch {
    // A storage read can throw in a locked-down environment (e.g. private
    // browsing quota errors on some browsers) — treat exactly like "empty".
    return [];
  }
  if (!raw) return [];

  try {
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    return parsed.filter((entry): entry is string => typeof entry === 'string');
  } catch {
    return [];
  }
}

/**
 * Records a visit to `path`, moving it to the front if already present
 * (dedup) and truncating to the `MAX_ENTRIES` most recent. No-ops silently
 * when `localStorage` is unavailable — a missed MRU record is never worth
 * surfacing an error over.
 */
export function recordVisit(path: string): void {
  if (!hasLocalStorage()) return;

  const next = [path, ...readStored().filter((p) => p !== path)].slice(0, MAX_ENTRIES);
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Storage full/unavailable at write time — same "not worth surfacing" posture as above.
  }
}

/** Most-recent-first list of visited page paths (max 10), or `[]` with no `localStorage` / no history yet. */
export function recentPages(): string[] {
  return readStored();
}
