<script lang="ts">
  import type { Snippet } from 'svelte';

  // Layout grid per DESIGN_SYSTEM §11: sidebar 236 · list pane 250-340 · main
  // flexible (content max 560-660) · rail 290-340.
  //
  // List pane ships as a fixed 300px column for Phase 1. shadcn-svelte's
  // Resizable (bits-ui PaneGroup) composes cleanly and is the natural
  // upgrade path once user-resizable panes are needed, but isn't installed
  // yet — deferred rather than adding a dependency this task doesn't need.
  // `mainVariant`:
  //  - 'prose' (default): the shell scrolls the whole main pane and centers
  //    content in the §11 max-width column — right for document-like pages.
  //  - 'column': the shell hands the route a full-height, non-scrolling
  //    flex column so it can pin chrome (e.g. the chat composer) to the
  //    pane's bottom edge and scroll only its transcript region.
  let {
    sidebar,
    list,
    main,
    rail,
    mainVariant = 'prose'
  }: {
    sidebar: Snippet;
    list?: Snippet;
    main: Snippet;
    rail?: Snippet;
    mainVariant?: 'prose' | 'column';
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
  {#if mainVariant === 'column'}
    <main class="flex min-h-0 min-w-0 flex-1 flex-col">
      {@render main()}
    </main>
  {:else}
    <main class="min-w-0 flex-1 overflow-y-auto">
      <div class="mx-auto max-w-[660px] px-8 py-8">
        {@render main()}
      </div>
    </main>
  {/if}
  {#if rail}
    <aside
      class="w-[320px] min-w-[290px] max-w-[340px] shrink-0 overflow-y-auto border-l border-paper-hairline bg-paper-panel"
    >
      {@render rail()}
    </aside>
  {/if}
</div>
