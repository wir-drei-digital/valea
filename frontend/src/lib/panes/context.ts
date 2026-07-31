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
