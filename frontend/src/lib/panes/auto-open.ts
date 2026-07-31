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
 * rather than trusting the width figure it is handed — and, like them, it
 * exempts the FIRST file from that cap (rule 0). A split needs
 * `TREE_W + SPLIT_MIN` = 540px of pane, which a two-pane row does not reach
 * until roughly a 1590px window, so on any normal laptop the width figure is
 * 0; treating that as "open nothing" would leave an assistant read or a tool
 * chip inert in an empty pane at exactly the widths people work at.
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
 *
 * ONE removal deliberately needs no `shiftAuto`, and it is worth recording so
 * nobody "fixes" it: `openInFirst`/`openAsSecond` can SHRINK the list when the
 * width cap has dropped to one. That is safe because the only index they can
 * strand is the one they truncate away, so the stale claim is always
 * `>= paths.length` — rule 1's `autoIndex < paths.length` guard rejects it and
 * the next auto-open falls through to rule 2 or 3. Nothing the user placed is
 * reachable through it. (The slot those two DO overwrite is index 0, and that
 * is a user open, which `clearAuto` covers.)
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

  // 0. The FIRST file always lands, whatever the width says — the same floor
  //    `openInFirst`/`openAsSecond` take, and safe here for the same reason:
  //    rule 3 below exists to protect a file the USER placed, and an empty
  //    pane has none to protect. Without it, a tool chip or an assistant read
  //    landing in an EMPTY Files pane does nothing at all below roughly a
  //    1590px window, which is most laptops.
  if (paths.length === 0) return { paths: [path], autoIndex: 0 };

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
