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
   * There is deliberately no "open a file" control here. A header button has no
   * file to name, so it could only guess one — and a guess whose cost is the
   * wrong file opening is not worth shipping. The tree row's "Open in a new
   * tab" already names the file the user actually wants.
   *
   * COMPARE is the exception, and the reason it belongs here rather than in the
   * strip: it names no file at all. It puts the tab you are reading beside the
   * one you were reading before it, which is a property of the pane, not of any
   * row. It is also the last control in this feature that depends on a width,
   * because two columns genuinely do compete for the content area.
   *
   * Both pressed states read what is RENDERED (`treeShown`, `compareShown`),
   * never the preference or the descriptor: the body drops the tree when the
   * pane is too narrow to hold it beside a file, and falls back to one column
   * when two will not fit. A button announcing `aria-pressed="true"` over
   * something that is not on screen is a worse failure than a disabled one.
   */
  import Columns2 from '@lucide/svelte/icons/columns-2';
  import PanelRight from '@lucide/svelte/icons/panel-right';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let { state }: { state: FilesPaneState } = $props();

  const treeLabel = $derived(
    state.treeBlocked
      ? `Show the file tree — unavailable: ${state.treeBlocked.toLowerCase()}`
      : state.treeShown
        ? 'Hide the file tree'
        : 'Show the file tree'
  );

  const compareLabel = $derived(
    state.compareBlocked
      ? `Compare two files — unavailable: ${state.compareBlocked.toLowerCase()}`
      : state.compareShown
        ? 'Stop comparing'
        : 'Compare two files'
  );
</script>

<!-- Same `aria-disabled` rule as the tree toggle below. The guard lives in the
     body's `toggleCompare`, which covers pointer and keyboard alike. -->
<button
  type="button"
  title={state.compareBlocked ?? (state.compareShown ? 'Stop comparing' : 'Compare two files')}
  aria-label={compareLabel}
  aria-pressed={state.compareShown}
  aria-disabled={state.compareBlocked ? 'true' : undefined}
  onclick={() => state.toggleCompare?.()}
  class={[
    'hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    state.compareBlocked
      ? 'text-ink-meta cursor-default hover:bg-transparent'
      : state.compareShown
        ? 'text-ink-heading'
        : 'text-ink-meta hover:text-ink-heading'
  ]}
>
  <Columns2 class={['size-3.5', state.compareBlocked ? 'opacity-40' : '']} strokeWidth={1.5} />
</button>

<!-- `aria-disabled`, not the `disabled` attribute — the same rule the tree
     row's "Open beside" and the bar's ＋ Pane follow: a truly disabled button
     takes no pointer events, so its `title` never appears, and it leaves the
     tab order entirely, so a keyboard or screen-reader user could never reach
     the reason. The click guard lives in `toggleTree`, which covers pointer and
     keyboard activation alike. -->
<button
  type="button"
  title={state.treeBlocked ?? (state.treeShown ? 'Hide the file tree' : 'Show the file tree')}
  aria-label={treeLabel}
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
  <!-- `PanelRight`, because that is the edge the tree is on now. -->
  <PanelRight class={['size-3.5', state.treeBlocked ? 'opacity-40' : '']} strokeWidth={1.5} />
</button>
