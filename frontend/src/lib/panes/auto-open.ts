/**
 * Where a file the ASSISTANT opened lands inside a Files pane.
 *
 * The rule tracks the one split auto-open created, so the assistant recycles
 * its own while a file the user placed stays put: pin your file on the right
 * and let chat cycle references on the left. Rule 3 is the conservative floor
 * `hasOpenPane()` provides today — auto-open never evicts a user's file.
 *
 * Like the Files pane rules it shares `SPLIT_CAP` with, this decides how many
 * paths a Files descriptor ends up carrying, so it clamps to the hard cap
 * rather than trusting the width figure it is handed.
 *
 * CALLERS MUST MAINTAIN THE CLAIM. It is an INDEX into `paths`, so it stops
 * meaning what it meant the moment the list is renumbered:
 *
 *   - user opens into split i  → `clearAuto(autoIndex, i)`
 *   - `closeSplit(paths, i)`   → `shiftAuto(autoIndex, i)`
 *   - `dropVanished(paths, p)` → `shiftAuto(autoIndex, paths.indexOf(p))`
 *
 * EVERY call site that removes a split has to route the claim through
 * `shiftAuto` — the Files pane's own close button and the vanished-subject
 * path alike. Skip one and the claim points at whatever slid into that slot,
 * and the next auto-open silently overwrites a file the USER placed, which is
 * the exact invariant this module exists to hold.
 */
import { SPLIT_CAP } from './files-pane-state';

export type AutoOpen = { paths: string[]; autoIndex: number | null };

export function autoOpen(
  paths: string[],
  autoIndex: number | null,
  path: string,
  maxSplits: number
): AutoOpen {
  const cap = Math.min(SPLIT_CAP, maxSplits);
  if (cap < 1) return { paths, autoIndex: null };
  if (paths.includes(path)) return { paths, autoIndex };

  // 1. Recycle the split auto-open created, if it still exists.
  if (autoIndex !== null && autoIndex >= 0 && autoIndex < paths.length) {
    const next = [...paths];
    next[autoIndex] = path;
    return { paths: next, autoIndex };
  }

  // 2. Take a free slot.
  if (paths.length < cap) {
    return { paths: [...paths, path], autoIndex: paths.length };
  }

  // 3. Both splits are the user's — do nothing.
  return { paths, autoIndex: null };
}

/** A user-initiated open into `userIndex` releases the assistant's claim on it. */
export function clearAuto(autoIndex: number | null, userIndex: number): number | null {
  return autoIndex === userIndex ? null : autoIndex;
}

/**
 * Re-maps the assistant's claim when a split is removed. `closeSplit` and
 * `dropVanished` renumber the list, so a claim held as an index would
 * otherwise point at whatever slid into that slot — and the next auto-open
 * would overwrite a file the user placed.
 *
 * `removedIndex` of -1 (an `indexOf` miss, i.e. nothing was actually removed)
 * leaves the claim untouched.
 */
export function shiftAuto(autoIndex: number | null, removedIndex: number): number | null {
  if (autoIndex === null || removedIndex < 0) return autoIndex;
  if (autoIndex === removedIndex) return null;
  return autoIndex > removedIndex ? autoIndex - 1 : autoIndex;
}
