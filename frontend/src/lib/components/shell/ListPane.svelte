<script lang="ts">
  import type { Snippet } from 'svelte';
  import { ScrollArea } from '$lib/components/ui/scroll-area/index.js';

  // List-pane chrome per the cockpit screens: a Newsreader pane title with an
  // optional action button on the same row, an optional filter-pill row under
  // it, then the scrolling list and an optional pinned footer. `title` is the
  // pane's name ("Mail", "Chat", a folder name) — page titles per
  // DESIGN_SYSTEM §3 are Newsreader 21–24, and the pane header uses the low
  // end of that band.
  let {
    title,
    action,
    filter,
    children,
    footer
  }: {
    title: string;
    action?: Snippet;
    filter?: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>

<div class="flex h-full flex-col">
  <div class="flex flex-col gap-2.5 px-4 pt-4 pb-3">
    <div class="flex items-center justify-between gap-2">
      <h1 class="font-display text-[21px] leading-tight font-medium text-ink-heading">{title}</h1>
      {#if action}
        {@render action()}
      {/if}
    </div>
    {#if filter}
      <div class="flex flex-wrap items-center gap-1">
        {@render filter()}
      </div>
    {/if}
  </div>
  <ScrollArea class="min-h-0 flex-1 border-t border-paper-hairline">
    {@render children()}
  </ScrollArea>
  {#if footer}
    <div class="border-t border-paper-hairline px-4 py-2.5">
      {@render footer()}
    </div>
  {/if}
</div>
