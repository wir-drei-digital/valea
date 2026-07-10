<script lang="ts">
  // Sticky dock above the Composer showing the agent's current `plan` item
  // (docs/DESIGN_SYSTEM.md — workflow timeline vocabulary, adapted to a
  // one-line summary + expandable checklist rather than the full §11
  // numbered-circle timeline, which is built for a different surface).
  //
  // SECURITY: entry.text is agent-authored plan-step text — plain
  // interpolation only, {@html} FORBIDDEN, per the module-wide note in
  // Transcript.svelte.
  import Check from '@lucide/svelte/icons/check';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import ChevronUp from '@lucide/svelte/icons/chevron-up';
  import type { AcpItemLike } from './item-shapes';
  import { planEntries, planProgress, isPlanEntryDone } from './item-shapes';

  let { item }: { item: AcpItemLike | undefined } = $props();

  const entries = $derived(planEntries(item));
  const progress = $derived(planProgress(entries));

  let expanded = $state(false);
</script>

{#if entries.length > 0}
  <div class="border-paper-hairline bg-paper-panel border-b px-4 py-2">
    <button type="button" onclick={() => (expanded = !expanded)} class="flex w-full items-center gap-2 text-left">
      <span class="text-overline">Plan</span>
      <span class="border-paper-chip-border bg-paper-card rounded-sm border px-1.5 py-px font-mono text-[10.5px] font-bold text-ink-secondary">
        {progress.done} of {progress.total} done
      </span>
      {#if progress.current}
        <span class="min-w-0 flex-1 truncate text-[12.5px] text-ink-body">{progress.current.text}</span>
      {:else}
        <span class="min-w-0 flex-1 truncate text-[12.5px] text-ink-meta">All steps complete</span>
      {/if}
      {#if expanded}
        <ChevronUp class="text-ink-meta size-3.5 shrink-0" aria-hidden="true" />
      {:else}
        <ChevronDown class="text-ink-meta size-3.5 shrink-0" aria-hidden="true" />
      {/if}
    </button>

    {#if expanded}
      <ul class="mt-2 flex flex-col gap-1">
        {#each entries as entry, i (i)}
          {@const done = isPlanEntryDone(entry.status)}
          {@const now = entry.status === 'in_progress'}
          <li class="flex items-center gap-2 text-[12.5px]" class:opacity-60={done} class:line-through={done}>
            <span class="flex size-3.5 shrink-0 items-center justify-center">
              {#if done}
                <Check class="text-act-dot size-3" aria-hidden="true" />
              {:else if now}
                <span class="bg-suggest-dash size-1.5 rounded-full" aria-hidden="true"></span>
              {:else}
                <span class="border-paper-chip-border size-1.5 rounded-full border" aria-hidden="true"></span>
              {/if}
            </span>
            <span class="min-w-0 flex-1 truncate {now ? 'font-medium text-ink-heading' : 'text-ink-body'}">
              {entry.text}
            </span>
          </li>
        {/each}
      </ul>
    {/if}
  </div>
{/if}
