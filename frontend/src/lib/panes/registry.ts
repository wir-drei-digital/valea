/**
 * kind -> pane entry. THE one place to extend when a new view becomes
 * pane-mountable.
 *
 * An entry is no longer a bare component. `PaneHost` renders the pane header
 * BEFORE mounting the view, so a pane cannot hand stateful chrome upward to
 * its already-rendering parent. Instead the host calls `createState` once per
 * pane and passes the result to both `controls` (in the header) and `view`
 * (in the body). Kinds needing no extras omit both fields and degrade to the
 * old shape.
 */
import type { Component } from 'svelte';
import type { PaneDescriptor } from './pane-route';
import type { PaneContext } from './context';
import FilesPane from '$lib/components/panes/FilesPane.svelte';
import FilesPaneControls from '$lib/components/panes/FilesPaneControls.svelte';
import ChatPane from '$lib/components/panes/ChatPane.svelte';
import ChatPaneControls from '$lib/components/panes/ChatPaneControls.svelte';
import MailPane from '$lib/components/panes/MailPane.svelte';
import { createFilesPaneState, type FilesPaneState } from './files-pane-runtime.svelte';
import { createChatPaneState, type ChatPaneState } from './chat-pane-runtime.svelte';

/**
 * A union of the concrete states, deliberately NOT an open
 * `Record<string, unknown>`: class instances carry no implicit index
 * signature, so the open-record form would reject every state that actually
 * exists. Views narrow on `state.kind`.
 *
 * The host additionally releases a state on teardown if it grew a `dispose()`
 * — see `PaneHost`'s `disposeState`. Neither state owns anything to release
 * today, so neither declares one.
 */
export type PaneState = FilesPaneState | ChatPaneState;

export type PaneEntry = {
  view: Component<{ descriptor: PaneDescriptor; context: PaneContext; state?: PaneState }>;
  controls?: Component<{ state: PaneState }>;
  createState?: (descriptor: PaneDescriptor) => PaneState;
};

// The `as unknown as` casts are the documented cost of the uniform map: each
// view's `descriptor` prop is narrower than `PaneDescriptor`. Every component
// guards on `descriptor.kind` internally, and PaneHost only ever mounts the
// component its own descriptor's `kind` selected here.
export const paneEntries: Record<PaneDescriptor['kind'], PaneEntry> = {
  files: {
    view: FilesPane as unknown as PaneEntry['view'],
    controls: FilesPaneControls as unknown as PaneEntry['controls'],
    createState: createFilesPaneState as unknown as PaneEntry['createState']
  },
  chat: {
    view: ChatPane as unknown as PaneEntry['view'],
    controls: ChatPaneControls as unknown as PaneEntry['controls'],
    createState: createChatPaneState as unknown as PaneEntry['createState']
  },
  // A `chat-new` pane is the same component with no sessions navigator and no
  // state: there is no session to list until it has started, at which point
  // the host rewrites the descriptor to `chat:<id>` and it remounts with both.
  'chat-new': { view: ChatPane as unknown as PaneEntry['view'] },
  mail: { view: MailPane as unknown as PaneEntry['view'] }
};
