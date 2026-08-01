/**
 * The two edits every pane host makes to its own pane list, as pure functions
 * so all four routes share one implementation and one set of tests.
 *
 * Both ALWAYS ALLOCATE. `PaneHost` derives its row layout from the `panes`
 * prop, and a same-identity array with mutated contents does not re-derive:
 * paneforge then recomputes the row from stale `defaultSize`s and writes them
 * back over the ratio the user just dragged (`paneRowLayout`'s doc comment has
 * the full chain). Handing the host a mutated array is the bug; handing it a
 * fresh one is the fix, and it is cheap enough to be unconditional.
 */
import { closeTabPath } from './files-pane-state';
import type { PaneDescriptor } from './pane-route';

/**
 * `panes` with the pane at `index` replaced, or removed when `next` is null.
 * An out-of-range index changes nothing — a stale callback from a pane that
 * has already left the row must not corrupt the list.
 */
export function replaceAt(
  panes: PaneDescriptor[],
  index: number,
  next: PaneDescriptor | null
): PaneDescriptor[] {
  if (index < 0 || index >= panes.length) return [...panes];
  if (next === null) return panes.filter((_, j) => j !== index);
  return panes.map((p, j) => (j === index ? next : p));
}

/**
 * What a pane becomes when ONE of its subjects vanishes — `null` meaning "the
 * host should close it".
 *
 * Per subject, not per pane: a Files descriptor can name six files, and
 * closing the whole pane because one of them was deleted would discard the
 * others and any pending edit in them. So a deleted tab is dropped and its
 * siblings stay, and a Files pane with nothing left survives as its tree —
 * taking the navigator away as collateral for one deleted file is a worse
 * answer than leaving it there. Chat and Mail hold one subject each and so
 * close outright: a layout that quietly shrinks is less alarming than one
 * carrying a dead panel.
 *
 * The drop goes through `closeTab`, not through a bare `filter`, because
 * removing a tab RENUMBERS the ones after it: `active` and `compare` are
 * indexes into that list, and a stale one either renders the wrong file or
 * renders none at all.
 *
 * Returns the pane UNCHANGED (same identity) when the subject was not one of
 * its own, which is how a caller tells "nothing happened" from "something did"
 * without a second flag.
 */
export function dropSubject(pane: PaneDescriptor, subject: string): PaneDescriptor | null {
  if (pane.kind !== 'files') return null;
  if (!pane.paths.includes(subject)) return pane;
  return { ...pane, ...closeTabPath(pane, subject) };
}
