/**
 * How much room the window has for panes — the ONE measurement behind "may
 * another pane open", shared by every control that opens one. What the answer
 * MEANS (the cap, the width, a surface already on screen) is
 * `pane-offer.ts`'s, which is pure and tested; this object only supplies the
 * `slots` it needs.
 *
 * It is a module singleton because both of its inputs already are. The window's
 * width is global by definition, and the nav's collapse is PERSISTED precisely
 * because every route mounts its own `AppShell` (see `loadNavVisible`). Holding
 * the answer inside one shell is what let a route-owned control open a pane at
 * the exact moment the bar beneath it was refusing one: at a 900px window the
 * knowledge routes' picker opened a chat pane into a ~130px column — two or
 * three words per line and a clipped composer — while ＋ Pane, six pixels
 * below, was correctly `aria-disabled` with "Not enough width for another
 * pane". Retiring the bar makes this singleton more load-bearing rather than
 * less: no control sees the whole row by construction any more.
 *
 * This object only ever ANSWERS the question. It never acts on it, and nothing
 * here re-runs when the window narrows: a pane already on screen stays, because
 * unmounting one would dispose a live `ChatView`'s session store and drop the
 * composer's draft. See `pane-fit.ts`'s header.
 */
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
}

export const paneRoom = new PaneRoom();
