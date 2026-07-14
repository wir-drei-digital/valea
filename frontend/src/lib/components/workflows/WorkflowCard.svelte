<script lang="ts">
  // Friendly contract card over one icm/Workflows/*.md file (DESIGN_SYSTEM
  // §11): name → description → trigger/risk/source chips → numbered step
  // timeline (the LAST step is the only green circle — the approval step) →
  // footer "Edit →" into the Knowledge page. Disabled workflows render at
  // 0.75 opacity with a neutral "NOT ACTIVE YET" badge instead of a colored
  // kind badge (§5: neutral = informational, nothing here is unsafe).
  import type { WorkflowListItem } from '$lib/stores/workflows.svelte';
  import { mountProvenanceLabel, workflowEditHref } from './workflowHref';

  let { workflow }: { workflow: WorkflowListItem } = $props();

  const steps = $derived(
    Array.isArray(workflow.steps) ? workflow.steps.filter((s): s is string => typeof s === 'string') : []
  );

  const editHref = $derived(workflowEditHref(workflow.resolvedPath));
  // A-T15: "· <mount>" provenance — only rendered once multiple mounts can
  // carry a same-named Workflows/ contract; `null` (missing/blank name)
  // renders nothing rather than a bare "·".
  const provenance = $derived(mountProvenanceLabel(workflow.icmName));

  const riskStyle: Record<string, string> = {
    low: 'bg-act-tint text-act',
    medium: 'bg-suggest-tint text-suggest-ink',
    high: 'bg-warn-tint text-warn-ink'
  };

  const riskClasses = $derived(riskStyle[workflow.riskLevel] ?? 'bg-paper-track text-ink-secondary');
</script>

<article
  class="border-paper-border bg-paper-card shadow-card flex flex-col gap-3 rounded-xl border px-5 py-[18px] {workflow.enabled
    ? ''
    : 'opacity-75'}"
>
  <div class="flex items-start justify-between gap-3">
    <h3 class="font-display text-ink-heading text-[17px]">
      {workflow.name}
      {#if provenance}
        <span class="text-ink-meta text-[13px] font-normal">{provenance}</span>
      {/if}
    </h3>
    {#if !workflow.enabled}
      <span
        class="bg-paper-track text-ink-secondary inline-flex w-fit shrink-0 items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
      >
        Not active yet
      </span>
    {/if}
  </div>

  {#if workflow.description}
    <p class="text-ink-body text-[13.5px] leading-normal">{workflow.description}</p>
  {/if}

  <div class="flex flex-wrap items-center gap-1.5">
    {#if workflow.triggerSource}
      <span
        class="border-paper-chip-border bg-paper-track text-ink-secondary inline-flex items-center rounded-full border px-2 py-0.5 font-mono text-[11px]"
      >
        {workflow.triggerSource}
      </span>
    {/if}
    {#if workflow.enabled}
      <!-- One accent at a time (§1): a disabled card already carries the
           neutral "Not active yet" badge, so the risk accent is suppressed. -->
      <span
        class="inline-flex items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase {riskClasses}"
      >
        {workflow.riskLevel ?? 'unknown'} risk
      </span>
    {/if}
    {#if typeof workflow.sourceCount === 'number'}
      <span class="border-paper-chip-border bg-paper-track text-ink-secondary inline-flex items-center rounded-full border px-2 py-0.5 text-[11.5px]">
        {workflow.sourceCount} source{workflow.sourceCount === 1 ? '' : 's'}
      </span>
    {/if}
  </div>

  {#if steps.length > 0}
    <ol class="flex flex-col gap-3 pt-1">
      {#each steps as step, i (i)}
        {@const isLast = i === steps.length - 1}
        <li class="relative flex gap-3 pl-9">
          {#if i < steps.length - 1}
            <span
              class="bg-paper-chip-border absolute top-6 left-[11px] h-[calc(100%+4px)] w-[1.5px]"
              aria-hidden="true"
            ></span>
          {/if}
          <span
            class="absolute top-0 left-0 flex size-6 shrink-0 items-center justify-center rounded-full border text-[11px] font-semibold {isLast
              ? 'bg-act-tint border-act text-act'
              : 'border-paper-chip-border bg-paper-card text-ink-secondary'}"
          >
            {i + 1}
          </span>
          <p class="text-ink-body pt-0.5 text-[13px] leading-normal">{step}</p>
        </li>
      {/each}
    </ol>
  {/if}

  <div class="flex flex-wrap items-center gap-3 pt-0.5">
    {#if editHref}
      <a href={editHref} class="text-act hover:text-act-hover text-[13px] font-semibold">Edit &rarr;</a>
    {/if}
    <span class="text-ink-meta font-mono text-[11px]">open the raw file — one toggle away in Knowledge</span>
  </div>
</article>
