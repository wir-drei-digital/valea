import type { PaneDescriptor } from './pane-route';

/**
 * What a host provides to a mounted view. Views must tolerate every callback
 * being absent.
 */
export type PaneContext = {
  placement: 'primary' | 'pane';
  /** Open a file in the single Files surface, creating one if there is none. */
  openFile?: (sel: { mountKey: string; path: string }) => void;
  /**
   * The Files surface announcing itself as where an `openFile` lands, with a
   * handler on mount and `null` on teardown.
   *
   * It is a handover rather than a computation because the host cannot do the
   * arithmetic: which split an assistant-opened file should take depends on
   * the CLAIM auto-open holds over the split it created (an index into that
   * surface's own `paths`, living in per-pane state the route never sees) and
   * on how wide the surface is (its split cap is measured from its own
   * element). A host that computed the landing itself would have to guess both
   * and would evict a file the user placed.
   *
   * A host with no registered target falls back to the claimless floor in
   * `auto-open.ts`, which is conservative rather than wrong.
   */
  registerFileTarget?: (open: ((path: string) => void) | null) => void;
  /**
   * The path this Files surface was CREATED to show, when the host created it
   * for an assistant open rather than for the user. `null` otherwise — a
   * surface the user opened, one restored from memory, one a link named.
   *
   * It exists because that one open is the only one that lands before the
   * component does, so it is the only one whose claim cannot be recorded by
   * `registerFileTarget`'s handler. Left unclaimed, the assistant's first read
   * sits in a split it can never recycle and its second read takes the other
   * one — on the very flow that opens a Files pane in the first place.
   *
   * ONE-SHOT: asking consumes it, so a re-registration cannot re-claim a split
   * the user has since taken over.
   */
  takeAutoCreatedPath?: () => string | null;
  /**
   * REWRITE the calling surface's own descriptor — replace it in place, never
   * append a pane.
   *
   * Every pane uses it that way and only that way: a Files tree click rewrites
   * its own `paths`, a mail row its own `msgId`, a session row its own
   * `sessionId`. A host that implements this as "open another pane" spawns a
   * second Files pane on every single tree click. The pane's index is already
   * in scope — hosts build this through `paneContext(descriptor, index)` — and
   * a primary view rewrites the route's own URL instead.
   *
   * Creating a surface that does not exist yet is `openFile`'s job, not this
   * one's.
   */
  openPane?: (d: PaneDescriptor) => void;
  /**
   * APPEND a pane beside this view, for a control that composes from the side
   * it is on — mail's "Start a session about this message", the session
   * header's "Open files". The opposite of `openPane`, which rewrites the
   * caller's own descriptor.
   *
   * Always paired with `besideRefusal`, and a control must render that reason
   * rather than call this and hope: at the cap, at a narrow window, or with a
   * surface of the same kind already on screen, this is a no-op by design.
   * `openFile` is still the way to create a Files surface AROUND A FILE — this
   * one opens a browser with nothing picked.
   */
  openBeside?: (d: PaneDescriptor) => void;
  /**
   * Why `openBeside` would refuse a pane of this kind right now, `null` when it
   * would succeed. A THUNK, not a value: it is read at render time by controls
   * that live several components below the host, and the answer changes with
   * the window and with the row.
   */
  besideRefusal?: (kind: PaneDescriptor['kind']) => string | null;
  /** A chat-new view created its session — host rewrites its descriptor to `chat:<id>`. */
  sessionCreated?: (id: string) => void;
  /** The view's whole subject was archived/removed — host closes this pane. */
  onArchived?: () => void;
  /**
   * ONE subject inside a multi-subject pane vanished (a Files split's file was
   * deleted). Per the spec's per-subject rule the host drops that subject and
   * keeps the pane if anything is left — never closes the pane wholesale.
   */
  onVanished?: (subject: string) => void;
};

export type { PaneDescriptor };
