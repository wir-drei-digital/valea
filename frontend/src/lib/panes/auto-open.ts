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
