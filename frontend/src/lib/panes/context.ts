import type { PaneDescriptor } from './pane-route';

/**
 * What a host (route or PaneHost) provides to a mounted view (side-panes
 * pass). Views must tolerate every callback being absent.
 */
export type PaneContext = {
  placement: 'primary' | 'pane';
  /** Open a file somewhere sensible for this host (side pane on /chat; primary navigation on /knowledge). */
  openFile?: (sel: { mountKey: string; path: string }) => void;
  /** A chat-new view created its session — host rewrites its descriptor to `chat:<id>`. */
  sessionCreated?: (id: string) => void;
  /** The view's subject was archived/removed — host should close/navigate away. */
  onArchived?: () => void;
};

export type { PaneDescriptor };
