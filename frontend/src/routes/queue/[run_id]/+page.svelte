<script lang="ts">
  // Full-draft review route — the ONLY place a queue item can be approved
  // (docs/DESIGN_SYSTEM.md — approval never lives on the ApprovalCard
  // summary, only here). Loads the raw `queue_item/v1` envelope via
  // `queueStore.detail` (= `api.getQueueItem`, T15/T16) and hands it to
  // `DraftReview` for the actual approve/reject flow. This route only owns
  // the LOAD state machine (loading / ok / gone / invalid / error) — the
  // approve/reject/changed/gone-after-action states live in DraftReview
  // itself, since those only make sense once a draft is actually on screen.
  import { page } from '$app/state';
  import { onMount } from 'svelte';
  import { AppFrame } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import { queueStore } from '$lib/stores/queue.svelte';
  import type { QueueItemEnvelope } from '$lib/api/client';
  import DraftReview from '$lib/components/queue/DraftReview.svelte';

  const runId = $derived(page.params.run_id ?? '');

  type LoadState = 'loading' | 'ok' | 'gone' | 'invalid' | 'error';
  let loadState: LoadState = $state('loading');
  let item: QueueItemEnvelope | null = $state(null);
  let revision: string | null = $state(null);
  let errorMessage = $state('');

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
        loadState = 'gone';
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

  onMount(() => {
    void load();
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
    {:else if item && revision}
      <DraftReview {item} {revision} {runId} onReload={() => void load()} />
    {/if}
  {/snippet}
</AppFrame>
