<script lang="ts">
  // Source chips for queue items (ApprovalCard, DraftReview): dot color
  // follows `sourceDot` (docs/DESIGN_SYSTEM.md §2/§5/§6 source-dot
  // semantics), and a chip is clickable → its Knowledge page only when
  // `sourceHref` resolves one. Distinct from
  // `$lib/components/today/SourceChips.svelte`, whose seeded strings are
  // untyped narrative fragments ("her email") rather than workspace paths —
  // this component is the one that actually differentiates dot color and
  // linkability per source.
  import { sourceDot, sourceHref, SOURCE_DOT_CLASS } from './sourceDot';

  let { sources }: { sources: string[] } = $props();
</script>

<div class="flex flex-wrap items-center gap-1.5">
  {#each sources as source (source)}
    {@const href = sourceHref(source)}
    {#if href}
      <a
        {href}
        class="border-paper-chip-border bg-paper-track text-ink-secondary hover:bg-paper-pill inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11.5px] transition-colors"
      >
        <span class="size-1.5 shrink-0 rounded-full {SOURCE_DOT_CLASS[sourceDot(source)]}" aria-hidden="true"
        ></span>
        {source}
      </a>
    {:else}
      <span
        class="border-paper-chip-border bg-paper-track text-ink-secondary inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11.5px]"
      >
        <span class="size-1.5 shrink-0 rounded-full {SOURCE_DOT_CLASS[sourceDot(source)]}" aria-hidden="true"
        ></span>
        {source}
      </span>
    {/if}
  {/each}
</div>
