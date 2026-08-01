/**
 * The ROUTE side of the pane contract, written once instead of four times.
 *
 * Every pane host answers the same four questions — what a pane's own
 * callbacks do, what closing one means, what promoting one means, and where a
 * file opened from inside a pane lands — and the answers carry details that
 * drift the moment they are copied: which navigations use `replaceState`,
 * which keep focus, and the rule that a vanished subject is dropped per
 * subject rather than closing the pane. Routes differ only in what their
 * primary view is, which is `openInPrimary` below.
 *
 * Every pane list handed to `withPanes` comes from `pane-edit.ts`, which
 * always allocates. `PaneHost` stops re-deriving its row layout when given a
 * mutated array, and paneforge then writes stale sizes back over a dragged
 * ratio.
 */
import { goto } from '$app/navigation';
import { autoOpen } from './auto-open';
import { TAB_CAP, resolveTabs, type TabState } from './files-pane-state';
import { dropSubject, replaceAt } from './pane-edit';
import { recallFilesPane, rememberFilesPane } from './pane-memory';
import { paneRefusal } from './pane-offer';
import {
  PANE_CAP,
  dedupeSurfaces,
  promoteTarget,
  withPanes,
  type PaneDescriptor
} from './pane-route';
import type { PaneContext } from './context';

export type FileSelection = { mountKey: string; path: string };

/** A brand-new Files surface showing exactly one file: one tab, active, no compare. */
function openedTab(path: string): TabState {
  return { paths: [path], active: 0, compare: null };
}

export type PaneWiring = {
  paneContext: (d: PaneDescriptor, index: number) => PaneContext;
  closePane: (index: number) => void;
  promotePane: (d: PaneDescriptor) => void;
  openFileSurface: (sel: FileSelection) => void;
  /**
   * Append a pane, for any control that opens one from the side it is on:
   * mail's "Start a session", the session header's "Open files", the knowledge
   * routes' session picker. Deduped against the primary, and GUARDED by
   * `besideRefusal` — the guard is the second half of the `aria-disabled`
   * pattern the controls use, covering keyboard activation and a stale closure.
   */
  openBeside: (d: PaneDescriptor) => void;
  /**
   * Why `openBeside` would refuse a pane of this kind right now, or `null` when
   * it would succeed. Every control that opens a pane must render this rather
   * than click into nothing — see `pane-offer.ts`.
   */
  besideRefusal: (kind: PaneDescriptor['kind']) => string | null;
  /** Whether a SIDE pane of this kind is on screen — the primary is not one. */
  besideOpen: (kind: PaneDescriptor['kind']) => boolean;
  /**
   * Close the side pane of this kind, if there is one. The other half of a
   * TOGGLE: a control that opens a pane and then goes dead because the pane it
   * opened is open is a control that spends most of its life disabled, so the
   * session header's file browser closes from the same button it opens from.
   */
  closeBeside: (kind: PaneDescriptor['kind']) => void;
};

export function paneWiring(read: {
  /** The live URL — a thunk, so every call reads the current navigation. */
  url: () => URL;
  /** The live pane list, already deduped against the route's primary. */
  panes: () => PaneDescriptor[];
  /** The route's own primary surface, so an appended pane cannot duplicate it. */
  primary?: () => PaneDescriptor | null;
  /**
   * How THIS route opens a file when its own primary IS the Files surface
   * (both knowledge routes). Absent means the route has no Files surface of
   * its own, so a file opens into a Files pane instead.
   */
  openInPrimary?: (sel: FileSelection) => void;
  /**
   * How many side panes this window has room for — `paneRoom.slots`, passed as
   * a thunk so this module stays free of `window` and stays unit-testable.
   * `besideRefusal` alone consults it; `openFileSurface` deliberately does not,
   * for the reason its own body records.
   *
   * Absent means "no opinion" and reads as unlimited, which is what a route
   * with no pane-opening control of its own wants — but every route that has
   * one must pass it, or its control cannot refuse on width.
   */
  slots?: () => number;
}): PaneWiring {
  function go(next: PaneDescriptor[], replace = false): void {
    // Focus and scroll are kept on every one of these: opening a file from a
    // tool chip mid-stream must not yank the transcript or blur the composer.
    void goto(withPanes(read.url(), next), {
      keepFocus: true,
      noScroll: true,
      replaceState: replace
    });
  }

  /**
   * Where an assistant-opened file lands, announced by the mounted Files pane
   * itself (`PaneContext.registerFileTarget`). Only that component can see
   * both inputs the rule needs: the claim on the split auto-open created (an
   * index into that pane's own `paths`, held in per-pane state this module
   * never sees) and the pane's measured width. So the file is handed over
   * rather than placed from out here.
   */
  let fileTarget: ((path: string) => void) | null = null;

  /**
   * The path a Files pane was CREATED to show, waiting for that pane to mount
   * and claim it. It is an assistant open like any other, but the only one
   * that lands before there is a component to record the claim in.
   */
  let autoCreatedPath: string | null = null;

  /**
   * The file targets the SINGLE Files surface — `dedupeSurfaces` guarantees
   * there is at most one across the primary and the panes.
   */
  function openFileSurface(sel: FileSelection): void {
    if (read.openInPrimary) {
      read.openInPrimary(sel);
      return;
    }
    const panes = read.panes();
    const at = panes.findIndex((p) => p.kind === 'files');
    if (at === -1) {
      // No Files surface yet. The cap is the only refusal — a row already
      // holding two panes cannot grow a third. Width is deliberately NOT
      // consulted, unlike `openBeside` below: refusing to show a file the
      // assistant just cited would be a silent failure, and the same reasoning
      // floors `openInFirst` at one file however narrow the pane is.
      //
      // That rationale only holds because the pane it creates ADAPTS. It used
      // to invert: at a 900px window this made a 260px Files pane whose fixed
      // 240px `shrink-0` tree left the file a 20px column, so the pane became
      // the silent failure the width was ignored to avoid, and cost a slot
      // doing it. `FilesPane` now drops the tree rather than the file
      // (`treeFits`), which is what makes ignoring the width honest here.
      if (panes.length >= PANE_CAP) return;
      autoCreatedPath = sel.path;
      go([...panes, { kind: 'files', mountKey: sel.mountKey, ...openedTab(sel.path) }]);
      return;
    }
    const pane = panes[at];
    if (pane.kind !== 'files') return;
    if (pane.mountKey !== sel.mountKey) {
      // Another ICM is another file browser. Re-point the pane at it rather
      // than pushing a foreign path into a descriptor that still names the
      // old mount — `files:<old>/<path from new>` addresses a file that does
      // not exist. The pane's identity changes with its mount, so the host
      // hands it a fresh state and the old claim goes with it — which is
      // exactly why the new one has to be left behind here, the same as for a
      // pane created from nothing above. Without it the file lands in a split
      // no claim covers: never recycled, never released, and the pane spends
      // the rest of its life with one dead half.
      autoCreatedPath = sel.path;
      go(replaceAt(panes, at, { kind: 'files', mountKey: sel.mountKey, ...openedTab(sel.path) }));
      return;
    }
    if (fileTarget) {
      fileTarget(sel.path);
      return;
    }
    // The pane has not announced itself (it is between mounts). Fall back to
    // the claimless floor: the first file always lands, an already-open file
    // is a no-op, a free tab is taken, and a pane whose tabs are all the
    // user's is left alone rather than evicting one.
    const next = autoOpen(pane.paths, null, sel.path, TAB_CAP);
    if (next.paths === pane.paths) return;
    // The file the assistant just opened is the one to SHOW — a tab that
    // arrives behind the one you are reading is a citation you never see.
    go(replaceAt(panes, at, { ...pane, ...resolveTabs(next.paths, next.paths.indexOf(sel.path), pane.compare) }));
  }

  function paneContext(_d: PaneDescriptor, index: number): PaneContext {
    return {
      placement: 'pane',
      registerFileTarget: (open) => {
        fileTarget = open;
      },
      takeAutoCreatedPath: () => {
        const path = autoCreatedPath;
        autoCreatedPath = null;
        return path;
      },
      // A REWRITE of this pane's own descriptor, never an append: a Files
      // tree click rewrites its `paths`, a mail row its `msgId`, a session
      // row its `sessionId`. Creating a surface is `openFile`'s job.
      openPane: (next) => go(replaceAt(read.panes(), index, next)),
      openFile: openFileSurface,
      // A view in a PANE composes the same way a route's primary does — a mail
      // pane may open a session beside itself, a chat pane a file browser. The
      // SAME function, so the two placements can never disagree about what the
      // row will accept.
      openBeside,
      besideRefusal,
      besideOpen,
      closeBeside: (kind) => {
        const at = read.panes().findIndex((p) => p.kind === kind);
        if (at !== -1) closePane(at);
      },
      // `replaceState` so Back does not step through the dead composer state.
      sessionCreated: (id) =>
        go(replaceAt(read.panes(), index, { kind: 'chat', sessionId: id }), true),
      // Self-closing, so Back never steps through a pane that immediately
      // removes itself.
      onArchived: () => go(replaceAt(read.panes(), index, null), true),
      /**
       * ONE subject inside a multi-subject pane vanished. The host drops that
       * subject and closes the pane only when nothing is left — the per-subject
       * rule, in `dropSubject`.
       *
       * It deliberately does NOT call `shiftAuto`. The assistant's auto-open
       * claim is an INDEX into a Files pane's `paths`, so a removal has to
       * re-map it — but `FilesPane.fileVanished` already does exactly that,
       * on the line before it calls this, because it is the only component
       * that can reach both the claim and the index being removed. Doing it
       * again here would apply the shift twice: idempotent when the claim sits
       * BELOW the removed index, but a claim above it would be released
       * instead of moved, silently costing the "recycle my own split"
       * behaviour the claim exists for. The split is the one from
       * `auto-open.ts`'s header — the pane owns the claim, the host owns the
       * descriptor.
       */
      onVanished: (subject) => {
        const panes = read.panes();
        const pane = panes[index];
        if (!pane) return;
        const next = dropSubject(pane, subject);
        // Same identity means the subject was not this pane's — a stale
        // callback from a descriptor that has already moved on.
        if (next === pane) return;
        go(replaceAt(panes, index, next), true);
      }
    };
  }

  /**
   * `openKinds` carries the route's own primary as well as the open panes,
   * because `dedupeSurfaces` counts it — a control offering a kind the primary
   * already IS would otherwise navigate to a URL that drops it again, which is
   * the silent no-op every one of these controls exists to avoid.
   */
  function besideRefusal(kind: PaneDescriptor['kind']): string | null {
    const panes = read.panes();
    const primary = read.primary?.() ?? null;
    return paneRefusal({
      open: panes.length,
      slots: read.slots?.() ?? Number.POSITIVE_INFINITY,
      openKinds: [...(primary ? [primary.kind] : []), ...panes.map((p) => p.kind)],
      wanted: kind
    });
  }

  /**
   * The guard, not merely the navigation: every control that calls this also
   * renders `besideRefusal` beside itself, and this re-checks because
   * `aria-disabled` leaves the button clickable on purpose (a truly `disabled`
   * one takes no pointer events, so its reason never appears, and it leaves
   * the tab order, so a keyboard user never finds it either).
   */
  function openBeside(d: PaneDescriptor): void {
    if (besideRefusal(d.kind)) return;
    go(dedupeSurfaces(read.primary?.() ?? null, [...read.panes(), reopened(d)]));
  }

  /**
   * A file browser asked for with NOTHING picked is a request for the file
   * browser, not for an empty one — so it comes back with the tabs it was
   * closed with (`pane-memory.ts`). Every other descriptor passes through
   * untouched, including a Files pane that names a file: that caller knows
   * exactly what it wants shown.
   */
  function reopened(d: PaneDescriptor): PaneDescriptor {
    if (d.kind !== 'files' || d.paths.length > 0) return d;
    return recallFilesPane(d.mountKey) ?? d;
  }

  // A user closing a pane is an ordinary navigation: Back reopens it.
  function closePane(index: number): void {
    const panes = read.panes();
    const closing = panes[index];
    // Remembered on the way out, which is the only moment the tabs and the
    // intent to close are both in hand. Back still restores the pane from the
    // URL — this is for the NEXT open, which starts from a control that knows
    // an ICM and nothing more.
    if (closing?.kind === 'files') rememberFilesPane(closing);
    go(replaceAt(panes, index, null));
  }

  function besideOpen(kind: PaneDescriptor['kind']): boolean {
    return read.panes().some((p) => p.kind === kind);
  }

  return {
    paneContext,
    closePane,
    promotePane: (d) => void goto(promoteTarget(d, read.url(), read.panes())),
    openFileSurface,
    besideRefusal,
    besideOpen,
    openBeside,
    closeBeside: (kind) => {
      const at = read.panes().findIndex((p) => p.kind === kind);
      if (at !== -1) closePane(at);
    }
  };
}
