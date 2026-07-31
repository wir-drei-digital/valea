<script lang="ts">
  /**
   * The Files pane's own header controls, rendered by PaneHost INSIDE the
   * shared pane header — so the pane has one header, one close button, and
   * per-kind extras. State is created by the host and shared with the body;
   * neither component parents the other.
   *
   * No accent colour: in this design system colour means consequence, and
   * showing or hiding a navigator has none. The pressed state reads as ink
   * weight instead.
   *
   * There is deliberately no "open a second file" control here. A header
   * button has no file to name, so it could only guess one — and a guess whose
   * cost is the wrong file opening, possibly over something the user was
   * reading in the second split, is not worth shipping. The tree row's "Open
   * beside" already names the file the user actually wants.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';
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
