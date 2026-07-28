<script lang="ts">
  // Shim between the registry's uniform `{descriptor, context}` contract and
  // `FileView`'s own `{mountKey, path}` props (side-panes pass). It also owns
  // the pane's scroll container + gutter, which the full route gets from
  // `MainColumn` — `FileView` itself is placement-agnostic and renders neither.
  import FileView from '$lib/components/views/FileView.svelte';
  import type { PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';

  let { descriptor, context }: { descriptor: PaneDescriptor; context: PaneContext } = $props();
</script>

{#if descriptor.kind === 'file'}
  <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
    <FileView mountKey={descriptor.mountKey} path={descriptor.path} onVanished={context.onArchived} />
  </div>
{/if}
