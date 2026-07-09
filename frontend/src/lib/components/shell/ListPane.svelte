<script lang="ts">
  import type { Snippet } from 'svelte';
  import { ScrollArea } from '$lib/components/ui/scroll-area/index.js';

  let {
    header,
    filter,
    children,
    footer
  }: {
    header: Snippet;
    filter?: Snippet;
    children: Snippet;
    footer?: Snippet;
  } = $props();
</script>

<div class="flex h-full flex-col">
  <div class="border-b border-paper-hairline px-3 py-3">
    {@render header()}
  </div>
  {#if filter}
    <div class="border-b border-paper-hairline px-3 py-2">
      {@render filter()}
    </div>
  {/if}
  <ScrollArea class="min-h-0 flex-1">
    {@render children()}
  </ScrollArea>
  {#if footer}
    <div class="border-t border-paper-hairline px-3 py-2">
      {@render footer()}
    </div>
  {/if}
</div>
