<script lang="ts">
  // A "new inquiry" cockpit card, given a real trust-loop front end (spec
  // Task 19): idle (unprepared) -> preparing (workflow running) -> the live
  // queue item once `New Inquiry Triage.md` finishes. Three renders, chosen
  // by matching `queueStore.items` against the triage workflow's path — NOT
  // by any local "did I click prepare" flag alone, so a page reload after a
  // previous run still shows the right state:
  //
  //   1. no matching queue item, not currently preparing -> the idle card,
  //      with "Prepare a reply" as its one primary action instead of the
  //      seed's "Review draft" (nothing has been drafted yet, so linking
  //      anywhere would be a lie).
  //   2. no matching queue item, `runWorkflow` in flight -> amber
  //      "PREPARING" in-progress state, linking to the live session.
  //   3. matching queue item, `valid: true` -> `ApprovalCard`, built from
  //      the FULL envelope (`queueStore.detail`, not the list summary —
  //      `list_items` deliberately omits `payload.sources`/`reasoning`/
  //      `session_id`, see `Valea.Queue.list/0`'s `summary/2`).
  //   4. ANY invalid queue item -> the muted "couldn't read" card (spec
  //      bullet). NOT matched by `workflow`: `Valea.Queue.list/0`'s
  //      `invalid_entry/2` always reports `workflow: nil` for a file that
  //      failed to decode — an item this broken can't be attributed to any
  //      ONE card by data alone. KNOWN LIMITATION (Task 18 generalized this
  //      card to render once per review message, all sharing this same
  //      workflow): an invalid item still surfaces on EVERY rendered card,
  //      same as the single-card Phase-1 behavior this preserves — there is
  //      no information in an invalid entry to attribute it to just one.
  //
  // Task 18 generalized this from one hardcoded Priya Nair instance to
  // `{path, fromName, summary, sources}` props, so `routes/+page.svelte`
  // can render one of these per mail review message. Every prop defaults to
  // the SEED values (the Priya Nair message + the cockpit narrative's rich
  // hand-authored summary and its four source chips), so the unconfigured
  // Today page — which renders exactly one card, passing at most the
  // cockpit payload's own byte-identical summary/usedSources — looks
  // EXACTLY like the pre-Task-18 seed card. The configured multi-card path
  // passes a generic subject-derived summary (`genericSummary` in
  // triage-card.ts) and NO sources instead: real synced messages carry no
  // seeded narrative or source attribution until a run produces one.
  //
  // Multiple concurrent cards run the SAME workflow against DIFFERENT
  // inputs, so `matching` can no longer be "the first pending item for this
  // workflow" (every card would then converge on whichever run resolves
  // first) — `matchedRunId` below disambiguates: the FAST path is a run
  // THIS card itself started (`prepareReply`'s response hands back
  // `runId` directly); the SLOW path (a reload, where no local state
  // survives) probes each unmatched candidate's full envelope for one whose
  // `input` equals this card's own `path` (`envelopeInputPath`).
  import { api } from '$lib/api/client';
  import type { QueueItemEnvelope } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import SourceChips from './SourceChips.svelte';
  import ApprovalCard from '$lib/components/queue/ApprovalCard.svelte';
  // Task 9.5: "· <mount>" provenance — same formatter `WorkflowCard.svelte`
  // uses for a workflow's owning ICM.
  import { mountProvenanceLabel } from '$lib/components/workflows/workflowHref';
  import {
    SEED_TRIAGE_PATH,
    SEED_TRIAGE_FROM_NAME,
    SEED_TRIAGE_SUMMARY,
    SEED_TRIAGE_SOURCES,
    envelopeInputPath,
    triageTitle,
    runWorkflowErrorMessage
  } from './triage-card';

  let {
    path = SEED_TRIAGE_PATH,
    fromName = SEED_TRIAGE_FROM_NAME,
    summary = SEED_TRIAGE_SUMMARY,
    sources = SEED_TRIAGE_SOURCES,
    // A-T15: sourced from the cockpit/today payload's live
    // `triageWorkflowPath` (T13's `Valea.Cockpit.today/0`), not a hardcoded
    // const — `null` when no enabled mount has a seeded triage workflow.
    // `routes/+page.svelte` passes `today?.triageWorkflowPath ?? null`.
    triageWorkflowPath = null,
    // Task 7.2: `run_workflow`'s new `{mountKey, relativePath}` identity —
    // sourced from the SAME cockpit payload's `triageWorkflowMountKey`/
    // `triageWorkflowRelativePath` (`null` together with `triageWorkflowPath`
    // above whenever no enabled mount has one).
    triageWorkflowMountKey = null,
    triageWorkflowRelativePath = null,
    // Task 9.5: the owning ICM's display name (sourced from the cockpit
    // payload's `preparedItems` entry for this seeded narrative — see
    // `routes/+page.svelte`'s `seedInquiry` derivation), or `null` when
    // underivable. Shown next to the title so this card, like every other
    // workspace-wide Today item, names its owning ICM.
    icmName = null
  }: {
    path?: string;
    fromName?: string;
    summary?: string;
    sources?: string[];
    triageWorkflowPath?: string | null;
    triageWorkflowMountKey?: string | null;
    triageWorkflowRelativePath?: string | null;
    icmName?: string | null;
  } = $props();

  const title = $derived(triageTitle(fromName));
  const icmLabel = $derived(mountProvenanceLabel(icmName));

  let preparing = $state(false);
  let sessionId: string | null = $state(null);
  let prepareError: string | null = $state(null);

  // The run id this card has resolved as "mine" — set either by
  // `prepareReply` (own click) or the reconciliation effect below (reload).
  // Sticky: once set, `matching` just tracks whatever `queueStore.items`
  // says about that run id (present-and-valid -> ApprovalCard; gone ->
  // decided elsewhere, card reverts to idle; a later `prepareReply` call
  // overwrites it with the new run's id).
  let matchedRunId: string | null = $state(null);
  const checkedRunIds = new Set<string>();

  const candidates = $derived(
    queueStore.items.filter((i) => i.valid && !!triageWorkflowPath && i.workflow === triageWorkflowPath)
  );
  const invalidItem = $derived(queueStore.items.find((i) => !i.valid));
  const matching = $derived(candidates.find((c) => c.runId === matchedRunId));

  // Reload-reconciliation: probe each not-yet-ruled-out candidate's full
  // envelope for one whose `input` equals this card's `path`. Re-runs
  // whenever `candidates` changes, but `checkedRunIds` means each run id is
  // only ever probed once.
  $effect(() => {
    if (matchedRunId) return;

    for (const candidate of candidates) {
      if (checkedRunIds.has(candidate.runId)) continue;
      checkedRunIds.add(candidate.runId);

      const runId = candidate.runId;
      void queueStore.detail(runId).then((result) => {
        if (matchedRunId) return; // beaten by a faster probe, or our own click
        if (!result.ok) return;
        if (envelopeInputPath(result.data.item) === path) {
          matchedRunId = runId;
        }
      });
    }
  });

  // Full envelope for the matched item, fetched once it turns up (the list
  // summary alone can't build ApprovalCard's sources/session-id). Keyed by
  // run id so a second, later run replaces rather than reuses a stale fetch.
  let envelope: QueueItemEnvelope | null = $state(null);
  let envelopeRunId: string | null = $state(null);

  $effect(() => {
    const target = matching;
    if (!target) return;
    if (envelopeRunId === target.runId) return;

    const runId = target.runId;
    envelopeRunId = runId;
    void queueStore.detail(runId).then((result) => {
      if (envelopeRunId !== runId) return; // superseded by a newer run while this was in flight
      if (result.ok) envelope = result.data.item;
    });
  });

  async function prepareReply(): Promise<void> {
    // defensive: the button is hidden whenever any of these is null
    if (!triageWorkflowMountKey || !triageWorkflowRelativePath) return;
    preparing = true;
    prepareError = null;
    const result = await api.runWorkflow(
      triageWorkflowMountKey,
      triageWorkflowRelativePath,
      { kind: 'workspace', path },
      workspaceStore.generation ?? 0
    );
    if (result.ok) {
      const data = result.data as { runId: string; sessionId: string };
      sessionId = data.sessionId;
      matchedRunId = data.runId;
    } else {
      preparing = false;
      prepareError = runWorkflowErrorMessage(result.error);
    }
  }
</script>

{#if matching && envelope && envelopeRunId === matching.runId}
  <ApprovalCard item={envelope} />
{:else if invalidItem}
  <article class="border-paper-hairline bg-paper-panel flex flex-col gap-2 rounded-xl border px-5 py-[18px] opacity-80">
    <p class="text-ink-body text-[13.5px]">The assistant produced something I couldn't read.</p>
    <p class="text-ink-meta font-mono text-[11px]">queue/pending/{invalidItem.runId}.json</p>
  </article>
{:else if preparing}
  <article
    class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2.5 rounded-xl border px-5 py-[18px]"
  >
    <span
      class="bg-suggest-tint text-suggest-ink inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
    >
      Preparing
    </span>
    <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">
      {title}
      {#if icmLabel}
        <span class="text-ink-meta text-[12.5px] font-normal">{icmLabel}</span>
      {/if}
    </h3>
    <p class="text-ink-body text-[13.5px] leading-normal">
      Drafting a reply — reading her email, your offer, and your tone guide.
    </p>
    {#if sessionId}
      <a
        href={`/chat?session=${sessionId}`}
        class="text-act hover:text-act-hover self-start text-[12.5px] font-semibold"
      >
        Watch the assistant work &rarr;
      </a>
    {/if}
  </article>
{:else}
  <article
    class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2.5 rounded-xl border px-5 py-[18px]"
  >
    <span
      class="bg-paper-track text-ink-secondary inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
    >
      New inquiry
    </span>
    <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">
      {title}
      {#if icmLabel}
        <span class="text-ink-meta text-[12.5px] font-normal">{icmLabel}</span>
      {/if}
    </h3>
    <p class="text-ink-body text-[13.5px] leading-normal">{summary}</p>
    {#if sources.length > 0}
      <SourceChips {sources} />
    {/if}
    {#if triageWorkflowMountKey && triageWorkflowRelativePath}
      <!-- A-T15: no seeded triage workflow (these are `null` together with
           `triageWorkflowPath`) means there is nothing to run — degrade
           gracefully by hiding the action entirely rather than wiring a
           button to a dead link. -->
      <div class="flex flex-wrap items-center gap-2 pt-0.5">
        <Button variant="default" onclick={() => void prepareReply()}>Prepare a reply</Button>
        {#if prepareError}
          <p class="text-warn-ink text-[12.5px]">{prepareError}</p>
        {/if}
      </div>
    {/if}
  </article>
{/if}
