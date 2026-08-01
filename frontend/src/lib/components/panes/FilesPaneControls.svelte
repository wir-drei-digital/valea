<script lang="ts">
  /**
   * Everything in the Files pane's header band: the TAB STRIP, then Compare and
   * the tree toggle. `PaneHost` renders this inside the shared pane header, so
   * the pane has one header, one close button, and per-kind extras.
   *
   * The strip lives here rather than above the content because two stacked
   * bands were two horizontal rules where the rest of the app has one, and a
   * pane title above a tab naming the same file said it twice. The registry
   * entry's `ownsTitle` is what suppresses that title — see `registry.ts`.
   *
   * State is created by the host and shared with the body; neither component
   * parents the other, and every action that rewrites the descriptor is a
   * handler the BODY registered, because only the body holds `PaneContext`.
   *
   * No accent colour: in this design system colour means consequence, and
   * switching a tab or showing a navigator has none. Every state here reads as
   * ink weight and paper instead.
   *
   * There is deliberately no "open a file" control. A header button has no file
   * to name, so it could only guess one. The tree row's "Open in a new tab"
   * names the file the user actually wants; ＋ opens an empty tab and lets them
   * pick.
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
  import Plus from '@lucide/svelte/icons/plus';
  import X from '@lucide/svelte/icons/x';
  import type { FilesPaneDescriptor } from '$lib/panes/pane-route';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let { descriptor, state }: { descriptor: FilesPaneDescriptor; state: FilesPaneState } = $props();

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

  function basename(path: string): string {
    return path.split('/').pop() ?? path;
  }
</script>

<!-- The strip takes the title's place and its width. Chips are `h-8` with
     `-my-1.5`, the same trick the header's buttons already use to keep a >=32px
     hit target without growing the band, so the rule across a multi-pane row
     still lines up with Chat's and Mail's. -->
<div class="-my-1.5 flex min-w-0 flex-1 items-center gap-1" aria-label="Open files">
  {#if descriptor.paths.length === 0 && !state.pendingTab}
    <!-- Nothing open: the pane still has to say what it is. Same typography as
         the title `PaneHost` renders for every other kind. -->
    <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
      Files
    </span>
  {/if}

  {#each descriptor.paths as path, i (path)}
    <!-- "Showing" is what is ON SCREEN: the active tab, plus the compare
         partner while two columns are rendered, and NEITHER while a pending tab
         holds the content area. -->
    {@const showing =
      !state.pendingTab &&
      (i === descriptor.active || (state.compareShown && i === descriptor.compare))}
    <div
      class={[
        'group/tab relative flex h-8 min-w-0 max-w-[180px] flex-1 items-center rounded-md transition-colors',
        showing ? 'bg-paper-card' : 'hover:bg-paper-pill'
      ]}
    >
      <!-- Plain buttons rather than a `tablist`: these tabs own no `tabpanel`
           to point at, and claiming the role would promise the arrow-key
           navigation the APG pattern requires. `aria-current` is the same
           marker `IcmTree` uses for the row you are reading. -->
      <button
        type="button"
        title={path}
        aria-current={!state.pendingTab && i === descriptor.active ? 'true' : undefined}
        onclick={() => state.showTab?.(i)}
        class={[
          'focus-visible:ring-ring/50 min-w-0 flex-1 truncate rounded-md py-1.5 pr-8 pl-2.5 text-left text-[12px] transition-colors outline-none focus-visible:ring-2',
          showing ? 'text-ink-heading' : 'text-ink-meta group-hover/tab:text-ink-heading'
        ]}
      >
        {basename(path)}
      </button>
      <!-- A sibling of the tab button, never nested inside it: a button within a
           button is invalid HTML and swallows the outer click target.
           `bg-inherit` takes the chip's own background so the ✕ sits cleanly
           over the truncated end of a long name. -->
      <button
        type="button"
        title="Close tab"
        aria-label={`Close ${basename(path)}`}
        onclick={() => state.closeTab?.(i)}
        class={[
          'text-ink-meta hover:text-ink-heading focus-visible:ring-ring/50 absolute top-0 right-0 flex size-8 items-center justify-center rounded-r-md bg-inherit transition-colors outline-none focus-visible:opacity-100 focus-visible:ring-2',
          showing ? 'opacity-100' : 'opacity-0 group-hover/tab:opacity-100'
        ]}
      >
        <X class="size-3" strokeWidth={1.5} />
      </button>
    </div>
  {/each}

  {#if state.pendingTab}
    <div
      class="bg-paper-card group/tab relative flex h-8 min-w-0 max-w-[180px] flex-1 items-center rounded-md"
    >
      <span
        class="text-ink-meta min-w-0 flex-1 truncate py-1.5 pr-8 pl-2.5 text-[12px] italic"
        aria-current="true"
      >
        New tab
      </span>
      <button
        type="button"
        title="Close tab"
        aria-label="Close the new tab"
        onclick={() => (state.pendingTab = false)}
        class="text-ink-meta hover:text-ink-heading focus-visible:ring-ring/50 absolute top-0 right-0 flex size-8 items-center justify-center rounded-r-md bg-inherit transition-colors outline-none focus-visible:ring-2"
      >
        <X class="size-3" strokeWidth={1.5} />
      </button>
    </div>
  {/if}

  <button
    type="button"
    title="New tab"
    aria-label="New tab"
    onclick={() => (state.pendingTab = true)}
    class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
  >
    <Plus class="size-3.5" strokeWidth={1.5} />
  </button>
</div>

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
    'hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    state.compareBlocked
      ? 'text-ink-meta cursor-default hover:bg-transparent'
      : state.compareShown
        ? 'text-ink-heading'
        : 'text-ink-meta hover:text-ink-heading'
  ]}
>
  <Columns2 class={['size-3.5', state.compareBlocked ? 'opacity-40' : '']} strokeWidth={1.5} />
</button>

<!-- `aria-disabled`, not the `disabled` attribute — the same rule the tree row's
     "Open in a new tab" and the bar's ＋ Pane follow: a truly disabled button
     takes no pointer events, so its `title` never appears, and it leaves the tab
     order entirely, so a keyboard or screen-reader user could never reach the
     reason. The click guard lives in `toggleTree`, which covers pointer and
     keyboard activation alike. -->
<button
  type="button"
  title={state.treeBlocked ?? (state.treeShown ? 'Hide the file tree' : 'Show the file tree')}
  aria-label={treeLabel}
  aria-pressed={state.treeShown}
  aria-disabled={state.treeBlocked ? 'true' : undefined}
  onclick={() => state.toggleTree()}
  class={[
    'hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
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
