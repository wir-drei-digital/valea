<script lang="ts">
  import type { Snippet } from 'svelte';

  // Rail cards ("why this draft") §10 — 290–340px, panel paper, Newsreader title.
  let { title, children }: { title: string; children: Snippet } = $props();
</script>

<div class="flex h-full flex-col gap-3 px-4 py-4">
  <h2 class="font-display text-[19px] text-ink-heading">{title}</h2>
  <div class="flex flex-1 flex-col gap-3 overflow-y-auto">
    {@render children()}
  </div>
</div>
