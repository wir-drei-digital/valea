import type { PaneDescriptor } from './pane-route';

/**
 * What a host provides to a mounted view. Views must tolerate every callback
 * being absent.
 */
export type PaneContext = {
  placement: 'primary' | 'pane';
  /** Open a file in the single Files surface, creating one if there is none. */
  openFile?: (sel: { mountKey: string; path: string }) => void;
  /** Open an arbitrary pane beside this one (subject to the cap and to fit). */
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
