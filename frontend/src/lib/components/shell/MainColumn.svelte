<script lang="ts">
  // The old AppShell 'prose' / 'prose-wide' main variants, relocated to the
  // route layer (side-panes pass): a scrolling column with either the §11
  // centered 660px prose cap (default) or the full pane width with just the
  // gutter (wide — page-editor pages, which re-cap per-block via tiptap.css).
  import type { Snippet } from 'svelte';

  let { wide = false, children }: { wide?: boolean; children: Snippet } = $props();
</script>

<div class="min-h-0 flex-1 overflow-y-auto">
  <div class={wide ? 'px-8 py-8' : 'mx-auto max-w-[660px] px-8 py-8'}>
    {@render children()}
  </div>
</div>
