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
 * Persisted as a plain JSON array of `{mountKey, path}` rows (most-recent-
 * first) under `localStorage['valea.recent-pages']` — deliberately just
 * `{mountKey, path}`, not full `{title, snippet}` rows: the palette
 * re-derives a display title from the path itself (see
 * `SearchPalette.svelte`), so a page renamed since its last visit doesn't
 * leave a stale title sitting in storage.
 *
 * Task 4.2/4.3 re-key: a page is addressed by `(mountKey, path)` now, not a
 * path alone (paths are ICM-relative and no longer globally unique across
 * mounts) — `mountKey` was added to this row shape for that reason. An
 * entry from before this change (a bare string, or an object missing
 * `mountKey`) can't be attributed to any mount, so it's silently dropped
 * rather than guessed at; the MRU list is capped and short-lived enough
 * that this just ages out within a few visits.
 */

const STORAGE_KEY = 'valea.recent-pages';
const MAX_ENTRIES = 10;

export type RecentPage = { mountKey: string; path: string };

function hasLocalStorage(): boolean {
  return typeof localStorage !== 'undefined';
}

/** Reads the persisted list, tolerating absent/corrupted/wrongly-shaped storage by falling back to empty. */
function readStored(): RecentPage[] {
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
    return parsed.filter(
      (entry): entry is RecentPage =>
        !!entry &&
        typeof entry === 'object' &&
        typeof (entry as Record<string, unknown>).mountKey === 'string' &&
        typeof (entry as Record<string, unknown>).path === 'string'
    );
  } catch {
    return [];
  }
}

/**
 * Records a visit to `(mountKey, path)`, moving it to the front if already
 * present (dedup on the pair, not path alone — the same relative path can
 * legitimately exist in two different mounts) and truncating to the
 * `MAX_ENTRIES` most recent. No-ops silently when `localStorage` is
 * unavailable — a missed MRU record is never worth surfacing an error over.
 */
export function recordVisit(mountKey: string, path: string): void {
  if (!hasLocalStorage()) return;

  const next = [
    { mountKey, path },
    ...readStored().filter((p) => !(p.mountKey === mountKey && p.path === path))
  ].slice(0, MAX_ENTRIES);

  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    // Storage full/unavailable at write time — same "not worth surfacing" posture as above.
  }
}

/** Most-recent-first list of visited `(mountKey, path)` pairs (max 10), or `[]` with no `localStorage` / no history yet. */
export function recentPages(): RecentPage[] {
  return readStored();
}
