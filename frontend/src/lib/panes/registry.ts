/**
 * kind -> view component for PaneHost (side-panes pass). THE one place to
 * extend when a new view becomes pane-mountable (mail, calendar, …): add a
 * descriptor variant in pane-route.ts, a component here, an entry point in
 * the owning route.
 */
import type { Component } from 'svelte';
import type { PaneDescriptor } from './pane-route';
import type { PaneContext } from './context';
import ChatView from '$lib/components/views/ChatView.svelte';
import FilePaneAdapter from '$lib/components/panes/FilePaneAdapter.svelte';

type PaneViewComponent = Component<{ descriptor: PaneDescriptor; context: PaneContext }>;

// The `as unknown as` casts are the documented cost of the uniform map:
// `ChatView`'s `descriptor` prop is narrower than `PaneDescriptor` (it only
// accepts the two chat variants) and `FilePaneAdapter` additionally exposes
// nothing, so neither is assignable to the shared signature without a cast.
// Both components guard on `descriptor.kind` internally, and PaneHost only
// ever mounts the component its own descriptor's `kind` selected here.
export const paneComponents: Record<PaneDescriptor['kind'], PaneViewComponent> = {
  file: FilePaneAdapter as unknown as PaneViewComponent,
  chat: ChatView as unknown as PaneViewComponent,
  'chat-new': ChatView as unknown as PaneViewComponent
};
