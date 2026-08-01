/**
 * Where a file the ASSISTANT opened lands inside a Files pane.
 *
 * The rule tracks the one TAB auto-open created, so the assistant recycles its
 * own while a file the user placed stays put: pin your file in one tab and let
 * chat cycle references through another. Rule 3 is the conservative floor
 * `hasOpenPane()` provides today — auto-open never evicts a user's file. That
 * is why it does not reach for `openInNewTab`'s cap eviction: a ＋ press is a
 * person asking for a tab, an assistant read is not.
 *
 * The rule is unchanged in shape by the move from splits to tabs; only what an
 * index counts changed. It still decides how many paths a Files descriptor
 * carries, so it still clamps to `TAB_CAP` rather than trusting the number it
 * is handed, and it still exempts the FIRST file (rule 0) so that a tool chip
 * or a citation is never inert in an empty pane.
 *
 * CALLERS MUST MAINTAIN THE CLAIM. It is an INDEX into `paths`, so it stops
 * meaning what it meant the moment the list is renumbered:
 *
 *   - user opens into tab i    → `clearAuto(autoIndex, i)`
 *   - `closeTab(state, i)`     → `shiftAuto(autoIndex, i)`
 *   - a tab's file vanished    → `shiftAuto(autoIndex, paths.indexOf(p))`
 *
 * The second removal is a PATH rather than an index because that is how it
 * arrives, and it does not happen here: `FilesPane.fileVanished` re-maps the
 * claim and then hands the subject up, and the host rewrites the descriptor
 * through `pane-edit.ts`'s `dropSubject` — per subject, so a deleted tab's
 * siblings survive. `dropSubject` is the only thing that removes a path there,
 * and it never sees the claim, which is why the pane has to shift it first.
 *
 * EVERY call site that removes a tab has to route the claim through
 * `shiftAuto` — the tab's own ✕, the vanished-subject path, and the tree's
 * Delete (which renumbers `paths` inside the URL through
 * `follow-mutation.ts`, and is reported back by `IcmTree`'s `onDeleted`
 * precisely so this one is not missed). Skip one and the claim points at
 * whatever slid into that slot, and the next auto-open silently overwrites a
 * file the USER placed, which is the exact invariant this module exists to
 * hold.
 *
 * Some rewrites report nothing at all — Back, and the primary Files surface
 * being navigated to another file or another ICM, which it outlives. Those
 * cannot be re-mapped, only refused, which is why `FilesPane` records the FILE
 * a claim was made for alongside the index and declines an index that no
 * longer holds it. That check is a floor under this contract, not a substitute
 * for it: it fails a claim closed where `shiftAuto` would have carried it.
 *
 * ONE removal deliberately needs no `shiftAuto`, and it is worth recording so
 * nobody "fixes" it: `openInNewTab` at the cap REPLACES the oldest inactive
 * tab in place rather than dropping it, so no index is renumbered at all. The
 * claim on the evicted slot fails closed by itself — `FilesPane` records the
 * file a claim was made for and refuses an index that no longer holds it.
 */
import { TAB_CAP } from './files-pane-state';

export type AutoOpen = { paths: string[]; autoIndex: number | null };

export function autoOpen(
  paths: string[],
  autoIndex: number | null,
  path: string,
  /** The tab cap, clamped to `TAB_CAP` — never trusted above it. */
  maxTabs: number
): AutoOpen {
  const cap = Math.min(TAB_CAP, maxTabs);

  // 0. The FIRST file always lands, whatever the cap says — the same floor
  //    `openInActiveTab` takes, and safe here for the same reason: rule 3
  //    below exists to protect a file the USER placed, and an empty pane has
  //    none to protect. Without it, a tool chip or an assistant read landing
  //    in an EMPTY Files pane could do nothing at all.
  if (paths.length === 0) return { paths: [path], autoIndex: 0 };

  if (cap < 1) return { paths, autoIndex: null };
  if (paths.includes(path)) return { paths, autoIndex };

  // 1. Recycle the tab auto-open created, if it still exists.
  if (autoIndex !== null && autoIndex >= 0 && autoIndex < paths.length) {
    const next = [...paths];
    next[autoIndex] = path;
    return { paths: next, autoIndex };
  }

  // 2. Take a free slot.
  if (paths.length < cap) {
    return { paths: [...paths, path], autoIndex: paths.length };
  }

  // 3. Every tab is the user's — do nothing.
  return { paths, autoIndex: null };
}

/** A user-initiated open into `userIndex` releases the assistant's claim on it. */
export function clearAuto(autoIndex: number | null, userIndex: number): number | null {
  return autoIndex === userIndex ? null : autoIndex;
}

/**
 * Re-maps the assistant's claim when a tab is removed. `closeTab` and
 * `dropSubject` renumber the list, so a claim held as an index would
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

/**
 * `shiftAuto` for a removal that takes SEVERAL tabs at once — deleting a
 * folder both open files live under, which arrives as one mutation and one
 * rewritten path list.
 *
 * The indexes are the ones the caller read off the list BEFORE anything was
 * removed, which is the only numbering it can observe. Applying them highest
 * first is what makes that safe: removing a higher index never renumbers a
 * lower one, so each index is still valid at the moment it is applied.
 * Ascending order would mis-map the second removal onto a list that has
 * already shifted under it.
 */
export function shiftAutoAll(autoIndex: number | null, removedIndexes: number[]): number | null {
  let claim = autoIndex;
  for (const index of [...removedIndexes].sort((a, b) => b - a)) {
    claim = shiftAuto(claim, index);
  }
  return claim;
}
