<script lang="ts">
  // The old AppShell 'prose' / 'prose-wide' main variants, relocated to the
  // route layer (side-panes pass): a scrolling column with either the §11
  // centered 660px prose cap (default) or the full pane width with just the
  // gutter (wide — page-editor pages, which re-cap per-block via tiptap.css).
  import type { Snippet } from 'svelte';

  // `pt-11` rather than `py-8`: the shell's nav toggle floats over the content
  // column's top-left corner (see `NavToggle.svelte`) and reaches 40px down.
  // The prose cap is CENTERED, so at a narrow window its left gutter collapses
  // and the first heading's opening letter lands under the control — 900px with
  // the nav shown was already there. Clearing it vertically keeps the column
  // centered, which a left gutter would not.
  let { wide = false, children }: { wide?: boolean; children: Snippet } = $props();
</script>

<div class="min-h-0 flex-1 overflow-y-auto">
  <div class={wide ? 'px-8 pt-11 pb-8' : 'mx-auto max-w-[660px] px-8 pt-11 pb-8'}>
    {@render children()}
  </div>
</div>
