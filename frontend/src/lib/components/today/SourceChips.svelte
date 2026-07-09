<script lang="ts">
  // "Used: " + source chips (DESIGN_SYSTEM §5) — every AI output names its
  // sources. Dot color will follow source-dot semantics once real sources
  // carry a type; the seeded strings are untyped, so all dots are the green
  // act-dot for now.
  let { sources }: { sources: string[] } = $props();
</script>

<div class="flex flex-wrap items-center gap-1.5">
  <span class="text-ink-meta text-[11.5px]">Used:</span>
  {#each sources as source (source)}
    <span
      class="border-paper-chip-border bg-paper-track text-ink-secondary inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11.5px]"
    >
      <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
      {source}
    </span>
  {/each}
</div>
