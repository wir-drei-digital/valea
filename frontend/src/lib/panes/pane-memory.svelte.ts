/**
 * The ROUTE side of pane memory: restore the last composition when a route is
 * entered, and record it as the user changes it.
 *
 * Written once instead of four times, for the same reason `pane-wiring.ts`
 * exists — the two halves are individually two lines and jointly subtle, and
 * four copies of "which one runs first, and what must it NOT write" would
 * drift on the first edit.
 *
 * The rules, in one place:
 *
 *   - **The URL always wins.** Memory is consulted only when the URL names no
 *     panes, so a link shared between two people is never rewritten by the
 *     recipient's habits (`restoreTarget`).
 *   - **A restore never writes.** What goes on screen may be TRUNCATED to the
 *     window's width while the stored row keeps every pane, so a composition
 *     that does not fit today comes back on a wider window tomorrow. Writing
 *     the truncated row back would quietly delete the pane that did not fit.
 *   - **Only a change the user made is stored.** The save half seeds itself
 *     with whatever the restore half put on screen and writes nothing until
 *     the composition moves away from it. Closing your last pane therefore
 *     does get remembered — the distinction is intent, not list length.
 */
import { goto } from '$app/navigation';
import { loadNavVisible, loadPanes, restoreTarget, routeKeyFor, savePanes } from './pane-memory';
import { serializePaneParam, withPanes, type PaneDescriptor } from './pane-route';

function fingerprint(panes: PaneDescriptor[]): string {
  return panes.map(serializePaneParam).join('\n');
}

export function watchPaneMemory(read: {
  /** The live URL — a thunk, so every call reads the current navigation. */
  url: () => URL;
  /** The live pane list, already deduped against the route's primary. */
  panes: () => PaneDescriptor[];
  /** The route's own primary surface, so a restore cannot duplicate it. */
  primary: () => PaneDescriptor | null;
}): void {
  // ONE restore per mounted route. Moving between sessions, messages or files
  // inside a route is not a fresh entry, and re-running there would fight the
  // user every time they closed a pane.
  let restored = false;
  // The composition already accounted for. `null` until one of the two effects
  // below seeds it — whichever runs first, which is why neither depends on the
  // order.
  let recorded: string | null = null;
  // A restore is on its way into the URL. Until it lands the URL still names
  // no panes, and storing that empty row would erase the very composition
  // being restored.
  let awaitingRestore = false;

  $effect(() => {
    const url = read.url();
    if (restored) return;
    restored = true;

    const key = routeKeyFor(url.pathname);
    if (!key) return;

    const target = restoreTarget({
      urlNamesPanes: url.searchParams.has('pane'),
      remembered: loadPanes(key),
      primary: read.primary(),
      // Read once, at the only moment width is consulted. `pane-fit.ts`'s
      // header has why this is never re-run on resize: unmounting a pane
      // because the window narrowed would drop a live session's channel.
      windowWidth: typeof window === 'undefined' ? undefined : window.innerWidth,
      navVisible: loadNavVisible()
    });

    // Whatever ends up on screen is what the save half must treat as already
    // accounted for — including a row the width forced us to cut short, which
    // must never be written back over the full one we still remember.
    recorded = fingerprint(target ?? read.panes());
    if (!target) return;

    awaitingRestore = true;
    // `goto` with `replaceState`, NOT `$app/navigation`'s shallow
    // `replaceState`. The shallow one was tried first — this is ambiguity
    // resolution, not really a navigation — and it moves the address bar
    // without moving `page.url`, so every `$derived(parsePanes(page.url…))`
    // in the route kept the empty list: the URL named a pane and the row was
    // still bare, until a reload. Caught in the browser, invisible to a unit
    // test. `replaceState: true` so Back does not step through the bare URL;
    // focus and scroll are kept because nothing about this is the user
    // navigating.
    void goto(withPanes(url, target), { replaceState: true, keepFocus: true, noScroll: true });
  });

  $effect(() => {
    const url = read.url();
    const key = routeKeyFor(url.pathname);
    if (!key) return;

    if (awaitingRestore) {
      // A restore only ever produces a non-empty row, so the presence of the
      // param is the landing signal.
      if (!url.searchParams.has('pane')) return;
      awaitingRestore = false;
    }

    const panes = read.panes();
    const now = fingerprint(panes);
    if (recorded === null) {
      recorded = now;
      return;
    }
    if (now === recorded) return;
    recorded = now;
    savePanes(key, panes);
  });
}
