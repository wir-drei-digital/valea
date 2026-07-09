<script lang="ts">
  import type { PreparedItem } from '$lib/today/cockpit';
  import { Button } from '$lib/components/ui/button/index.js';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import SourceChips from './SourceChips.svelte';

  // The reusable approval-card anatomy (DESIGN_SYSTEM §6):
  // kind badge → title → summary → source chips → actions.
  // Border --paper-border, radius 12, padding 18×20, internal gap 10,
  // "Why this?" always bottom-right.
  let { item }: { item: PreparedItem } = $props();

  // Kind-badge tint follows consequence (§5): green = prepared/safe,
  // neutral paper-track = informational. Nothing seeded is irreversible,
  // so no terracotta here.
  const kindMap: Record<string, { label: string; classes: string }> = {
    reply_drafted: { label: 'Reply drafted', classes: 'bg-act-tint text-act' },
    prep_brief: { label: 'Prep brief', classes: 'bg-paper-track text-ink-secondary' },
    follow_up_drafted: { label: 'Follow-up drafted', classes: 'bg-act-tint text-act' }
  };

  const kind = $derived(
    kindMap[item.type] ?? {
      label: item.type.replaceAll('_', ' '),
      classes: 'bg-paper-track text-ink-secondary'
    }
  );

  let whyOpen = $state(false);

  // Actions are visually real but inert this phase — approval flows land
  // with live data.
  function onPrimary() {
    console.info(`[today] primary action (no-op this phase): ${item.primaryAction} — ${item.title}`);
  }

  function onSecondary() {
    console.info(
      `[today] secondary action (no-op this phase): ${item.secondaryAction} — ${item.title}`
    );
  }
</script>

<article
  class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2.5 rounded-xl border px-5 py-[18px]"
>
  <span
    class="inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase {kind.classes}"
  >
    {kind.label}
  </span>

  <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">{item.title}</h3>

  <p class="text-ink-body text-[13.5px] leading-normal">{item.summary}</p>

  <SourceChips sources={item.usedSources} />

  <div class="flex flex-wrap items-center gap-2 pt-0.5">
    <Button variant="default" onclick={onPrimary}>{item.primaryAction}</Button>
    {#if item.secondaryAction}
      <Button variant="outline" onclick={onSecondary}>{item.secondaryAction}</Button>
    {/if}
    <button
      type="button"
      class="text-act hover:text-act-hover ml-auto self-end text-[12.5px] font-semibold"
      onclick={() => (whyOpen = true)}
    >
      Why this? &rarr;
    </button>
  </div>
</article>

<Dialog.Root bind:open={whyOpen}>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">Why this?</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        These are the sources the assistant used. Every suggestion shows its sources.
      </Dialog.Description>
    </Dialog.Header>
    <ul class="flex flex-col gap-2">
      {#each item.usedSources as source (source)}
        <li class="text-ink-body flex items-center gap-2 text-[13.5px]">
          <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
          {source}
        </li>
      {/each}
    </ul>
  </Dialog.Content>
</Dialog.Root>
