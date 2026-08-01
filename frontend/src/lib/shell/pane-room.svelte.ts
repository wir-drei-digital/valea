/**
 * How much room the window has for panes — the ONE answer to "may another pane
 * open", shared by the bar's ＋ Pane and by every route-owned control that
 * opens one (today the knowledge routes' session picker).
 *
 * It is a module singleton because both of its inputs already are. The window's
 * width is global by definition, and the nav's collapse is PERSISTED precisely
 * because every route mounts its own `AppShell` (see `loadNavVisible`). Holding
 * the answer inside one shell is what let a route-owned control open a pane at
 * the exact moment the bar beneath it was refusing one: at a 900px window the
 * knowledge routes' picker opened a chat pane into a ~130px column — two or
 * three words per line and a clipped composer — while ＋ Pane, six pixels
 * below, was correctly `aria-disabled` with "Not enough width for another
 * pane".
 *
 * This object only ever ANSWERS the question. It never acts on it, and nothing
 * here re-runs when the window narrows: a pane already on screen stays, because
 * unmounting one would dispose a live `ChatView`'s session store and drop the
 * composer's draft. See `pane-fit.ts`'s header.
 */
import { PANE_CAP } from '$lib/panes/pane-route';
import { loadNavVisible, saveNavVisible } from '$lib/panes/pane-memory';
import { panesThatFit } from './pane-fit';

class PaneRoom {
  /**
   * `undefined` until the window is measured — on the server there is no
   * window at all. Reads guard, because `panesThatFit(NaN, …)` returns NaN
   * (`spare < 0` is false for NaN, and `Math.min(2, NaN)` is NaN), and a NaN
   * pane count is a silent "no room" at best and a `RangeError` in whatever
   * tries to build an array of that many at worst.
   */
  width = $state<number | undefined>(
    typeof window === 'undefined' ? undefined : window.innerWidth
  );

  navVisible = $state(loadNavVisible());

  /** How many side panes this window has room for, 0 while unmeasured. */
  get slots(): number {
    return typeof this.width === 'number' && Number.isFinite(this.width)
      ? panesThatFit(this.width, this.navVisible)
      : 0;
  }

  toggleNav(): void {
    this.navVisible = !this.navVisible;
    saveNavVisible(this.navVisible);
  }

  /** Whether a row already holding `open` side panes may grow one more. */
  canAdd(open: number): boolean {
    return open < PANE_CAP && open < this.slots;
  }

  /**
   * Why not — for a control that must say so rather than fail silently. Read
   * only when `canAdd` is false; the cap outranks the width because it is the
   * one refusal no monitor can lift.
   */
  reasonFor(open: number): string {
    return open >= PANE_CAP
      ? 'Two panes beside the main view is the maximum'
      : 'Not enough width for another pane';
  }
}

export const paneRoom = new PaneRoom();
