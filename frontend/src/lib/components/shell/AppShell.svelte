<script lang="ts">
  import type { Snippet } from 'svelte';

  // Layout grid per DESIGN_SYSTEM §11: sidebar 236 · list pane 250-340 · main
  // flexible (content max 560-660) · rail 290-340.
  //
  // List pane ships as a fixed 300px column for Phase 1. shadcn-svelte's
  // Resizable (bits-ui PaneGroup) composes cleanly and is the natural
  // upgrade path once user-resizable panes are needed, but isn't installed
  // yet — deferred rather than adding a dependency this task doesn't need.
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
  <main class="min-w-0 flex-1 overflow-y-auto">
    <div class="mx-auto max-w-[660px] px-8 py-8">
      {@render main()}
    </div>
  </main>
  {#if rail}
    <aside
      class="w-[320px] min-w-[290px] max-w-[340px] shrink-0 overflow-y-auto border-l border-paper-hairline bg-paper-panel"
    >
      {@render rail()}
    </aside>
  {/if}
</div>
