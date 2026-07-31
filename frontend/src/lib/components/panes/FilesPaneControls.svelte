<script lang="ts">
  /**
   * The Files pane's own header controls, rendered by PaneHost INSIDE the
   * shared pane header — so the pane has one header, one close button, and
   * per-kind extras. State is created by the host and shared with the body;
   * neither component parents the other.
   *
   * No accent colour on either button: in this design system colour means
   * consequence, and showing or hiding a navigator has none. The pressed
   * state reads as ink weight instead.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import Columns2 from '@lucide/svelte/icons/columns-2';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let { state }: { state: FilesPaneState } = $props();
</script>

<button
  type="button"
  title={state.treeVisible ? 'Hide the file tree' : 'Show the file tree'}
  aria-label={state.treeVisible ? 'Hide the file tree' : 'Show the file tree'}
  aria-pressed={state.treeVisible}
  onclick={() => state.toggleTree()}
  class="hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 {state.treeVisible
    ? 'text-ink-heading'
    : 'text-ink-meta hover:text-ink-heading'}"
>
  <PanelLeft class="size-3.5" strokeWidth={1.5} />
</button>
<button
  type="button"
  title={state.maxSplits < 2 ? 'Not enough width for a second file' : 'Open a second file'}
  aria-label="Open a second file"
  disabled={state.maxSplits < 2 || !state.addSplit}
  onclick={() => state.addSplit?.()}
  class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 disabled:opacity-40 disabled:hover:bg-transparent"
>
  <Columns2 class="size-3.5" strokeWidth={1.5} />
</button>
