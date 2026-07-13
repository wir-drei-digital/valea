<script lang="ts">
  // Full-draft review route — the ONLY place a queue item can be approved
  // (docs/DESIGN_SYSTEM.md — approval never lives on the ApprovalCard
  // summary, only here). Loads the raw `queue_item/v1` envelope via
  // `queueStore.detail` (= `api.getQueueItem`, T15/T16) and hands it to
  // `DraftReview` for the actual approve/reject flow. This route only owns
  // the LOAD state machine (loading / ok / gone / invalid / error / decided)
  // — the approve/reject/changed/gone-after-action states live in
  // DraftReview itself, since those only make sense once a draft is
  // actually on screen.
  //
  // Task 18 adds the `decided` state: `getQueueItem` only ever reads
  // `queue/pending/` (`Valea.Queue.get/1`), so an ALREADY-decided item
  // (approved or rejected) comes back `queue_item_gone` — same as a
  // genuinely nonexistent run id. Rather than showing the terminal "Already
  // handled." dead end for both, the `queue_item_gone` branch below now
  // falls through to `api.listDecidedQueueItems()` (mail design spec,
  // §Mailbox ops) to look for `runId` there; if found, its mailbox-op
  // outcome rows render instead (with a Retry button on any `failed` op).
  // A run id that's in neither pending NOR decided (truly gone/never
  // existed) still falls back to "Already handled.".
  import { page } from '$app/state';
  import { onMount } from 'svelte';
  import { AppFrame } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { encodePath } from '$lib/shell/nav';
  import type { QueueItemEnvelope } from '$lib/api/client';
  import DraftReview from '$lib/components/queue/DraftReview.svelte';
  import MemoryUpdateReview from '$lib/components/queue/MemoryUpdateReview.svelte';
  import {
    findDecidedItem,
    mailboxOpRows,
    retryMailboxOpsErrorMessage,
    MAILBOX_OP_CHIP_CLASS,
    type DecidedQueueItem
  } from '$lib/components/queue/queue-ops';

  const runId = $derived(page.params.run_id ?? '');

  type LoadState = 'loading' | 'ok' | 'gone' | 'invalid' | 'error' | 'decided';
  let loadState: LoadState = $state('loading');
  let item: QueueItemEnvelope | null = $state(null);
  let revision: string | null = $state(null);
  let errorMessage = $state('');
  let decidedItem: DecidedQueueItem | null = $state(null);

  async function load(): Promise<void> {
    loadState = 'loading';
    const result = await queueStore.detail(runId);
    if (result.ok) {
      item = result.data.item;
      revision = result.data.revision;
      loadState = 'ok';
      return;
    }
    item = null;
    revision = null;
    switch (result.error) {
      case 'queue_item_gone':
        await loadDecided();
        break;
      case 'queue_item_invalid':
        loadState = 'invalid';
        break;
      case 'workspace_not_open':
        errorMessage = 'No workspace is open.';
        loadState = 'error';
        break;
      case 'workspace_changed':
        errorMessage = 'Your workspace changed. Reopen it and try again.';
        loadState = 'error';
        break;
      default:
        errorMessage = "Couldn't load this item. Please try again.";
        loadState = 'error';
    }
  }

  /** Looks for `runId` among the decided (approved/rejected) items; falls back to the plain "gone" dead end when it's genuinely nowhere. */
  async function loadDecided(): Promise<void> {
    const result = await api.listDecidedQueueItems();
    if (result.ok) {
      const data = result.data as { items?: unknown[] };
      const found = findDecidedItem(data.items ?? [], runId);
      if (found) {
        decidedItem = found;
        loadState = 'decided';
        return;
      }
    }
    decidedItem = null;
    loadState = 'gone';
  }

  const opRows = $derived.by(() => (decidedItem ? mailboxOpRows(decidedItem.mailboxOps) : []));
  // A `memory_update` decided item never has mailbox ops (B4) — its terminal
  // state is "the page was written" or "it was rejected", not a set of
  // mailbox-op outcomes, so the decided view substitutes plain text for the
  // ops list rather than rendering an always-empty section (see below).
  const isMemoryKind = $derived.by(() => decidedItem?.kind === 'memory_update');

  // Same shape rule as `MemoryUpdateReview.svelte`'s `linkableTarget` (B12):
  // only a workspace-relative `mounts/…` or absolute `.md` target has a
  // Knowledge page to link to.
  const linkableTarget = $derived.by(() => {
    const targetPath = decidedItem?.targetPath;
    return targetPath?.endsWith('.md') && (targetPath.startsWith('mounts/') || targetPath.startsWith('/'));
  });
  const appliedHref = $derived.by(() =>
    linkableTarget && decidedItem?.targetPath
      ? `/knowledge/${encodePath(decidedItem.targetPath)}`
      : null
  );

  let retrying = $state(false);
  let retryError: string | null = $state(null);

  async function retry(): Promise<void> {
    retrying = true;
    retryError = null;
    const generation = workspaceStore.generation ?? 0;
    const result = await api.retryMailboxOps(runId, generation);
    retrying = false;
    if (!result.ok) retryError = retryMailboxOpsErrorMessage(result.error);
    // No manual refetch on success: `retry_ops` runs in the background and
    // its outcome arrives via the `mailbox_ops` push wired below.
  }

  onMount(() => {
    void load();

    // Live outcome updates: a mailbox op finishing (or failing) after this
    // page has already loaded the decided item pushes `mailbox_ops` on the
    // shared `workspace:events` channel. `mailStore.onMailboxOps` (not a
    // second `channel.on` binding — see its doc comment) is the lightweight
    // subscription; unsubscribed on unmount so a navigated-away route never
    // keeps refetching in the background.
    const unsubscribe = mailStore.onMailboxOps((payload) => {
      if (payload.runId === runId) void loadDecided();
    });
    return unsubscribe;
  });
</script>

<AppFrame>
  {#snippet main()}
    {#if loadState === 'loading'}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {:else if loadState === 'gone'}
      <div class="flex flex-col items-start gap-3 py-10">
        <p class="text-ink-body text-[13.5px]">Already handled.</p>
        <a href="/" class="text-act hover:text-act-hover text-[13px] font-semibold">Back to Today &rarr;</a>
      </div>
    {:else if loadState === 'invalid'}
      <div class="flex flex-col items-start gap-3 py-10">
        <p class="text-ink-body text-[13.5px]">The assistant produced something I couldn't read.</p>
        <p class="text-ink-meta font-mono text-[11.5px]">queue/pending/{runId}.json</p>
        <a href="/" class="text-act hover:text-act-hover text-[13px] font-semibold">Back to Today &rarr;</a>
      </div>
    {:else if loadState === 'error'}
      <div class="flex flex-col items-start gap-3 py-10">
        <p class="text-ink-body text-[13.5px]">{errorMessage}</p>
        <Button variant="outline" size="sm" onclick={() => void load()}>Retry</Button>
      </div>
    {:else if loadState === 'decided' && decidedItem}
      <div class="flex flex-col gap-6">
        <header class="flex flex-col gap-2">
          <span
            class="{decidedItem.decided === 'approved'
              ? 'bg-act-tint text-act'
              : 'bg-paper-track text-ink-secondary'} inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
          >
            {decidedItem.decided === 'approved' ? 'Approved' : 'Rejected'}
          </span>
          <h1 class="font-display text-ink-heading text-[24px] leading-tight font-medium">
            {decidedItem.title ?? 'Untitled draft'}
          </h1>
        </header>

        {#if isMemoryKind}
          <p class="text-ink-body text-[13.5px]">
            {#if decidedItem.decided === 'approved'}
              {#if decidedItem.targetPath}
                Applied to <span class="font-mono text-[11.5px]">{decidedItem.targetPath}</span>
                {#if appliedHref}
                  · <a href={appliedHref} class="text-act hover:text-act-hover font-semibold">Open in Knowledge &rarr;</a>
                {/if}
              {:else}
                Applied.
              {/if}
            {:else if decidedItem.decision?.reason}
              Rejected — &ldquo;{decidedItem.decision.reason}&rdquo;
            {:else}
              Rejected.
            {/if}
          </p>
        {:else if decidedItem.decision?.reason}
          <p class="text-ink-body text-[13.5px]">Rejected — &ldquo;{decidedItem.decision.reason}&rdquo;</p>
        {/if}

        {#if !isMemoryKind && opRows.length > 0}
          <div>
            <p class="text-overline mb-2">Mailbox</p>
            <ul class="flex flex-col gap-2.5">
              {#each opRows as row (row.name)}
                <li
                  class="border-paper-border bg-paper-card flex items-center justify-between gap-3 rounded-xl border px-4 py-3"
                >
                  <div class="flex flex-col gap-1">
                    <span class="text-ink-heading text-[13.5px] font-medium">{row.label}</span>
                    {#if row.hint}
                      <span class="text-ink-meta text-[12px]">{row.hint}</span>
                    {/if}
                  </div>
                  <div class="flex shrink-0 items-center gap-2">
                    <span
                      class="{MAILBOX_OP_CHIP_CLASS[
                        row.chip
                      ]} inline-flex items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
                    >
                      {row.statusText}
                    </span>
                    {#if row.canRetry}
                      <Button variant="outline" size="sm" disabled={retrying} onclick={() => void retry()}>
                        {retrying ? 'Retrying…' : 'Retry'}
                      </Button>
                    {/if}
                  </div>
                </li>
              {/each}
            </ul>
            {#if retryError}
              <p class="text-warn-ink mt-2 text-[12.5px]" role="alert">{retryError}</p>
            {/if}
          </div>
        {/if}

        <a href="/" class="text-act hover:text-act-hover self-start text-[13px] font-semibold">Back to Today &rarr;</a>
      </div>
    {:else if item && revision}
      {#if item.payload?.kind === 'memory_update'}
        <MemoryUpdateReview {item} {revision} {runId} onReload={() => void load()} />
      {:else}
        <DraftReview {item} {revision} {runId} onReload={() => void load()} />
      {/if}
    {/if}
  {/snippet}
</AppFrame>
