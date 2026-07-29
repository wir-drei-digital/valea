<script lang="ts">
  import type { Snippet } from 'svelte';

  // Layout grid per DESIGN_SYSTEM §11: sidebar 236 · list pane 250-340 · main
  // flexible (content max 560-660) · rail 290-340.
  //
  // List pane ships as a fixed 300px column: it is the route's nav, not a
  // reading surface, so there is nothing to trade width against. Resizing
  // arrived one column over instead — `PaneHost` splits the MAIN slot with
  // `paneforge` (a real dependency now, `PaneGroup`/`Pane`/`PaneResizer`,
  // ratio persisted by `pane-split.ts`), which is where a reader actually
  // wants to trade one view's width for another's.
  //
  // The main slot is a bare full-height flex column — the old `mainVariant`
  // prop is gone (side-panes pass). Each route/view now owns its own scroll
  // container and width cap: `MainColumn` (this barrel) is the relocated
  // 'prose'/'prose-wide' wrapper, and routes that already pinned chrome to
  // the pane's bottom edge (chat's composer, calendar's grid) just render
  // their column straight into the slot. The shell staying variant-free is
  // what lets any view be rendered in any pane.
  let {
    sidebar,
    list,
    main,
    rail
  }: {
    sidebar: Snippet;
    list?: Snippet;
    main: Snippet;
    rail?: Snippet;
  } = $props();
</script>

<div class="flex h-screen bg-paper-surface text-ink-body">
  <aside class="w-[236px] shrink-0 border-r border-paper-hairline bg-paper-sidebar">
    {@render sidebar()}
  </aside>
  {#if list}
    <section
      class="w-[300px] min-w-[250px] max-w-[340px] shrink-0 overflow-y-auto border-r border-paper-hairline bg-paper-panel"
    >
      {@render list()}
    </section>
  {/if}
  <main class="flex min-h-0 min-w-0 flex-1 flex-col">
    {@render main()}
  </main>
  {#if rail}
    <aside
      class="w-[320px] min-w-[290px] max-w-[340px] shrink-0 overflow-y-auto border-l border-paper-hairline bg-paper-panel"
    >
      {@render rail()}
    </aside>
  {/if}
</div>
