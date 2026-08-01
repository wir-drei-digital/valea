/**
 * May another pane open right now — and if not, what to say.
 *
 * The bottom bar used to be the one place this was answered, and answering it
 * was most of what the bar was for: ＋ Pane went `aria-disabled` with the
 * reason on hover rather than clicking into nothing. The bar is gone and the
 * controls that open panes are scattered across mail, the session header and
 * the knowledge routes, so the answer has to live somewhere all of them can
 * reach — as a pure function, because a control that silently does nothing has
 * been this feature's recurring defect and a refusal deserves a test.
 *
 * Every refusal is a SENTENCE, not a boolean, and the ordering is the point:
 *
 *  1. Already open — true whatever the window is doing, and the only refusal
 *     the user can act on ("it is over there"). It comes first because a
 *     surface of this kind is dropped by `dedupeSurfaces` on the way to the
 *     URL, so without it the control appears to work and nothing happens.
 *  2. The cap — the one refusal no monitor can lift.
 *  3. The width — the one a wider window, or hiding the nav, does lift.
 *
 * Kinds are compared RAW, exactly as `dedupeSurfaces` compares them, so
 * `chat-new` beside `chat` stays legal (see `pane-route.ts`'s carve-out). If
 * this compared "a chat is a chat" the two would disagree and this would refuse
 * an open the URL would have accepted.
 */
import { PANE_CAP, type PaneDescriptor } from './pane-route';

export const CAP_REFUSAL = 'Two panes beside the main view is the maximum';
export const WIDTH_REFUSAL = 'Not enough width for another pane';

/** Why a pane of this kind cannot open when one is already on screen. */
export function alreadyOpenRefusal(kind: PaneDescriptor['kind']): string {
  switch (kind) {
    case 'files':
      return 'The file browser is already open beside this';
    case 'chat':
      return 'A session is already open beside this';
    case 'chat-new':
      return 'A new session is already open beside this';
    case 'mail':
      return 'Mail is already open beside this';
  }
}

/**
 * Room alone — the cap, then the width. For a control that opens a pane
 * without naming its kind up front (the knowledge routes' session picker
 * offers a new session OR any recent one).
 *
 * `open` is the number of SIDE panes; `slots` is how many this window has room
 * for (`paneRoom.slots`, 0 while unmeasured, which correctly refuses rather
 * than guessing).
 */
export function roomRefusal(open: number, slots: number): string | null {
  if (open >= PANE_CAP) return CAP_REFUSAL;
  if (open >= slots) return WIDTH_REFUSAL;
  return null;
}

/**
 * The full answer for a control that knows exactly what it would open.
 * `openKinds` is every kind already on screen — the route's own primary
 * INCLUDED, because `dedupeSurfaces` counts it too.
 */
export function paneRefusal(input: {
  open: number;
  slots: number;
  openKinds: string[];
  wanted: PaneDescriptor['kind'];
}): string | null {
  if (input.openKinds.includes(input.wanted)) return alreadyOpenRefusal(input.wanted);
  return roomRefusal(input.open, input.slots);
}
