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
   *
   * The pressed state reads `treeShown`, never `treeVisible`: the body drops
   * the tree when the pane is too narrow to hold it beside an open file, and a
   * button announcing `aria-pressed="true"` over an absent tree is a worse
   * failure than a disabled one — it names a state that is not on screen.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let { state }: { state: FilesPaneState } = $props();

  const label = $derived(
    state.treeBlocked
      ? `Show the file tree — unavailable: ${state.treeBlocked.toLowerCase()}`
      : state.treeShown
        ? 'Hide the file tree'
        : 'Show the file tree'
  );
</script>

<!-- `aria-disabled`, not the `disabled` attribute — the same rule the tree
     row's "Open beside" and the bar's ＋ Pane follow: a truly disabled button
     takes no pointer events, so its `title` never appears, and it leaves the
     tab order entirely, so a keyboard or screen-reader user could never reach
     the reason. The click guard lives in `toggleTree`, which covers pointer and
     keyboard activation alike. -->
<button
  type="button"
  title={state.treeBlocked ?? (state.treeShown ? 'Hide the file tree' : 'Show the file tree')}
  aria-label={label}
  aria-pressed={state.treeShown}
  aria-disabled={state.treeBlocked ? 'true' : undefined}
  onclick={() => state.toggleTree()}
  class={[
    'hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    state.treeBlocked
      ? 'text-ink-meta cursor-default hover:bg-transparent'
      : state.treeShown
        ? 'text-ink-heading'
        : 'text-ink-meta hover:text-ink-heading'
  ]}
>
  <PanelLeft class={['size-3.5', state.treeBlocked ? 'opacity-40' : '']} strokeWidth={1.5} />
</button>
