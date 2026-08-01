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
import { SPLIT_CAP } from './files-pane-state';
import { dropSubject, replaceAt } from './pane-edit';
import {
  PANE_CAP,
  dedupeSurfaces,
  promoteTarget,
  withPanes,
  type PaneDescriptor
} from './pane-route';
import type { PaneContext } from './context';

export type FileSelection = { mountKey: string; path: string };

export type PaneWiring = {
  paneContext: (d: PaneDescriptor, index: number) => PaneContext;
  closePane: (index: number) => void;
  promotePane: (d: PaneDescriptor) => void;
  openFileSurface: (sel: FileSelection) => void;
  /**
   * Append a pane, for a route-owned control that opens one (the knowledge
   * routes' session picker). The bar's ＋ Pane does the same thing from the
   * shell. Deduped against the primary, and a no-op once the row is full.
   */
  openBeside: (d: PaneDescriptor) => void;
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
   * The file targets the SINGLE Files surface — `dedupeSurfaces` guarantees
   * there is at most one across the primary and the panes.
   *
   * Where it lands inside an occupied pane is `auto-open.ts`'s rule, called
   * here with no claim: the first file always lands, an already-open file is
   * a no-op, a free split is taken, and a pane whose splits are both the
   * user's is left alone rather than evicting one. The other half of that
   * contract — remembering which split this opened so the next one recycles
   * it — needs a durable per-pane claim and arrives with the auto-open
   * dispatch; until then every assistant open is treated as a first one,
   * which is the conservative direction.
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
      // holding two panes cannot grow a third.
      if (panes.length >= PANE_CAP) return;
      go([...panes, { kind: 'files', mountKey: sel.mountKey, paths: [sel.path] }]);
      return;
    }
    const pane = panes[at];
    if (pane.kind !== 'files') return;
    const next = autoOpen(pane.paths, null, sel.path, SPLIT_CAP);
    if (next.paths === pane.paths) return; // nothing to do — already open, or both splits are the user's
    go(replaceAt(panes, at, { ...pane, paths: next.paths }));
  }

  function paneContext(_d: PaneDescriptor, index: number): PaneContext {
    return {
      placement: 'pane',
      // A REWRITE of this pane's own descriptor, never an append: a Files
      // tree click rewrites its `paths`, a mail row its `msgId`, a session
      // row its `sessionId`. Creating a surface is `openFile`'s job.
      openPane: (next) => go(replaceAt(read.panes(), index, next)),
      openFile: openFileSurface,
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

  return {
    paneContext,
    // A user closing a pane is an ordinary navigation: Back reopens it.
    closePane: (index) => go(replaceAt(read.panes(), index, null)),
    promotePane: (d) => void goto(promoteTarget(d, read.url(), read.panes())),
    openFileSurface,
    openBeside: (d) => {
      const panes = read.panes();
      if (panes.length >= PANE_CAP) return;
      go(dedupeSurfaces(read.primary?.() ?? null, [...panes, d]));
    }
  };
}
