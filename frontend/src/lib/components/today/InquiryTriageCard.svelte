<script lang="ts">
  // The Priya Nair "new inquiry" cockpit card, given a real trust-loop front
  // end (spec Task 19): idle (seeded, unprepared) -> preparing (workflow
  // running) -> the live queue item once `New Inquiry Triage.md` finishes.
  // Three renders, chosen by matching `queueStore.items` against the triage
  // workflow's path — NOT by any local "did I click prepare" flag, so a
  // page reload after a previous run still shows the right state:
  //
  //   1. no matching queue item, not currently preparing -> the seeded card
  //      (from `Valea.Cockpit.today/0`), with "Prepare a reply" as its one
  //      primary action instead of the seed's "Review draft" (nothing has
  //      been drafted yet, so linking anywhere would be a lie).
  //   2. no matching queue item, `runWorkflow` in flight -> amber
  //      "PREPARING" in-progress state, linking to the live session.
  //   3. matching queue item, `valid: true` -> `ApprovalCard`, built from
  //      the FULL envelope (`queueStore.detail`, not the list summary —
  //      `list_items` deliberately omits `payload.sources`/`reasoning`/
  //      `session_id`, see `Valea.Queue.list/0`'s `summary/2`).
  //   4. ANY invalid queue item -> the muted "couldn't read" card (spec
  //      bullet). NOT matched by `workflow`: `Valea.Queue.list/0`'s
  //      `invalid_entry/2` always reports `workflow: nil` for a file that
  //      failed to decode — an item this broken can't be attributed to a
  //      workflow, so it can't be matched by path. Since this phase only
  //      ever wires ONE workflow to a Today action, any invalid pending
  //      item is treated as this run having gone wrong.
  import { api } from '$lib/api/client';
  import type { QueueItemEnvelope } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { queueStore } from '$lib/stores/queue.svelte';
  import type { PreparedItem } from '$lib/today/cockpit';
  import { Button } from '$lib/components/ui/button/index.js';
  import SourceChips from './SourceChips.svelte';
  import ApprovalCard from '$lib/components/queue/ApprovalCard.svelte';

  const TRIAGE_WORKFLOW = 'icm/Workflows/New Inquiry Triage.md';
  const TRIAGE_INPUT = 'sources/mail/normalized/priya-nair-inquiry.json';

  let { item }: { item: PreparedItem } = $props();

  let preparing = $state(false);
  let sessionId: string | null = $state(null);
  let prepareError: string | null = $state(null);

  // Newest pending item from this workflow, and — separately — the newest
  // invalid pending item of ANY workflow (see the moduledoc-style comment
  // above for why invalid items can't be matched by `workflow`).
  // `queueStore.items` is already newest-first (`Valea.Queue.list/0`), and
  // both are reactive to it, so a `queue_changed` push (wired at the shared
  // `workspace:events` join, `wireIcmEvents` -> `wireQueueEvents`) flips
  // this card over without any polling here.
  const matching = $derived(queueStore.items.find((i) => i.valid && i.workflow === TRIAGE_WORKFLOW));
  const invalidItem = $derived(queueStore.items.find((i) => !i.valid));

  // Full envelope for the matching item, fetched once it turns up (the list
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
    preparing = true;
    prepareError = null;
    const result = await api.runWorkflow(TRIAGE_WORKFLOW, TRIAGE_INPUT, workspaceStore.generation ?? 0);
    if (result.ok) {
      const data = result.data as { runId: string; sessionId: string };
      sessionId = data.sessionId;
    } else {
      preparing = false;
      prepareError = runWorkflowErrorMessage(result.error);
    }
  }

  function runWorkflowErrorMessage(code: string): string {
    switch (code) {
      case 'harness_unavailable':
        return 'The assistant harness is not ready yet.';
      case 'workflow_disabled':
        return 'This workflow is turned off.';
      case 'input_not_found':
        return 'The inquiry email is missing.';
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'workspace_not_open':
        return 'No workspace is open.';
      default:
        return 'Could not start the assistant. Please try again.';
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
    <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">{item.title}</h3>
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
    <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">{item.title}</h3>
    <p class="text-ink-body text-[13.5px] leading-normal">{item.summary}</p>
    <SourceChips sources={item.usedSources} />
    <div class="flex flex-wrap items-center gap-2 pt-0.5">
      <Button variant="default" onclick={() => void prepareReply()}>Prepare a reply</Button>
      {#if prepareError}
        <p class="text-warn-ink text-[12.5px]">{prepareError}</p>
      {/if}
    </div>
  </article>
{/if}
