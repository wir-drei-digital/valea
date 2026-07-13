<script lang="ts">
  // Full review for a `memory_update` queue item — the memory-proposal twin
  // of `DraftReview.svelte` (docs/DESIGN_SYSTEM.md §6/§8/§10), reached the
  // same way: only from `/queue/[run_id]` (routed there by
  // `payload.kind === 'memory_update'`), never approved from the
  // `ApprovalCard` summary. Mirrors DraftReview's FSM/state conventions —
  // `idle|busy|approved|rejected|changed|gone|error` plus one more,
  // `conflict`, for B7's `apply_conflict` (the approve RPC re-checks the
  // base hash server-side; a mismatch writes NOTHING and hands the item
  // back to `pending/`, so this state — unlike DraftReview's, where
  // `apply_conflict` is unreachable post-routing — is the one case a
  // memory item's approve button can realistically hit even after the
  // client-side `staleBase` warning already fired).
  //
  // `buildMemoryReview` (memory-review.ts) does all the shape/derivation
  // work; this component owns state (the fetched `page`, the FSM) and
  // rendering only.
  //
  // SECURITY: `content_markdown` (rendered via `DiffBlock`'s rows) and
  // `reason`/`sources` are agent-authored. Plain interpolation only —
  // {@html} is FORBIDDEN here, same as every other agent-content
  // component.
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { api } from '$lib/api/client';
  import type { QueueItemEnvelope, IcmPageData } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import { tierCopy } from '$lib/components/agent/permission-view';
  import DiffBlock from '$lib/components/diff/DiffBlock.svelte';
  import QueueSourceChips from './QueueSourceChips.svelte';
  import { buildMemoryReview } from './memory-review';

  let {
    item,
    revision,
    runId,
    onReload
  }: {
    item: QueueItemEnvelope;
    revision: string;
    runId: string;
    /** Re-fetches `item`/`revision` from the parent route — see its "changed"/"conflict" reload paths. */
    onReload: () => void;
  } = $props();

  // Three states, not two: `undefined` — never fetched (create mode) OR a
  // fetch is still in flight; `null` — a fetch was ATTEMPTED and failed;
  // `IcmPageData` — loaded. Collapsing "still loading" into "failed" would
  // flash a false "Could not read the current page" notice (and the
  // all-add fallback diff) on every ordinary edit-mode open, for however
  // long the `api.icmPage` round trip takes — see the notice's guard below,
  // which checks `page === null` specifically, never `undefined`.
  // `buildMemoryReview` doesn't need the distinction (it only cares whether
  // real content is available yet), so it gets `page ?? null` either way.
  let page: IcmPageData | null | undefined = $state(undefined);

  const review = $derived(buildMemoryReview(item, page ?? null));

  // Same shape rule as `workflowHref.ts`'s `workflowEditHref` (kept local
  // rather than imported — that helper's doc is workflow-specific, and
  // duplicating one guard clause beats a cross-domain import for it): only
  // a workspace-relative `mounts/…` or absolute `.md` target has a
  // Knowledge page to link to.
  const linkableTarget = $derived(
    review.targetPath.endsWith('.md') && (review.targetPath.startsWith('mounts/') || review.targetPath.startsWith('/'))
  );
  // The header's own link is gated on `!isCreate` too: a create target has
  // no Knowledge page to open until AFTER approval writes it — linking to
  // it beforehand would land on Knowledge's not-found state. The
  // post-approval "Open in Knowledge" link (below) uses `appliedHref`
  // instead, which is NOT create-gated, since by then the page exists
  // regardless of which mode created it.
  const targetHref = $derived(!review.isCreate && linkableTarget ? `/knowledge/${encodePath(review.targetPath)}` : null);
  const appliedHref = $derived(linkableTarget ? `/knowledge/${encodePath(review.targetPath)}` : null);

  async function loadPage(): Promise<void> {
    if (review.isCreate || !review.targetPath.endsWith('.md')) return;
    const result = await api.icmPage(review.targetPath);
    page = result.ok ? result.data : null;
  }

  onMount(() => {
    void loadPage();
  });

  type Status = 'idle' | 'busy' | 'approved' | 'rejected' | 'changed' | 'gone' | 'conflict' | 'error';
  let status: Status = $state('idle');
  let errorMessage: string | null = $state(null);
  let actedAt: Date | null = $state(null);
  let reason = $state('');

  function applyErrorStatus(code: string): void {
    switch (code) {
      case 'queue_item_changed':
        status = 'changed';
        break;
      case 'queue_item_gone':
        status = 'gone';
        break;
      case 'apply_conflict':
        status = 'conflict';
        break;
      case 'workspace_not_open':
        status = 'error';
        errorMessage = 'No workspace is open.';
        break;
      case 'workspace_changed':
        status = 'error';
        errorMessage = 'Your workspace changed. Reopen it and try again.';
        break;
      default:
        status = 'error';
        errorMessage = 'Something went wrong. Please try again.';
    }
  }

  async function approve(): Promise<void> {
    status = 'busy';
    errorMessage = null;
    const result = await queueStore.approve(runId, revision);
    if (result.ok) {
      actedAt = new Date();
      status = 'approved';
      return;
    }
    applyErrorStatus(result.error);
  }

  async function reject(): Promise<void> {
    status = 'busy';
    errorMessage = null;
    const trimmed = reason.trim();
    const result = await queueStore.reject(runId, revision, trimmed || undefined);
    if (result.ok) {
      actedAt = new Date();
      status = 'rejected';
      return;
    }
    applyErrorStatus(result.error);
  }

  function formatTime(date: Date): string {
    return date.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  }
</script>

<div class="flex flex-col gap-6">
  <header class="flex flex-col gap-2">
    <span
      class="bg-act-tint text-act inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
    >
      Memory update
    </span>
    <p class="text-ink-meta font-mono text-[11.5px]">{review.mountLabel}</p>
    {#if targetHref}
      <a
        href={targetHref}
        class="font-display text-ink-heading hover:text-act text-[20px] leading-tight font-medium"
      >
        {review.targetPath}
      </a>
    {:else}
      <h1 class="font-display text-ink-heading text-[20px] leading-tight font-medium">{review.targetPath}</h1>
    {/if}
    {#if review.reason}
      <p class="text-ink-body text-[13.5px]">{review.reason}</p>
    {/if}
  </header>

  {#if review.sources.length > 0}
    <div>
      <p class="text-overline mb-2">Used</p>
      <QueueSourceChips sources={review.sources} />
    </div>
  {/if}

  {#if review.highRisk}
    <div role="alert" class="border-warn-border bg-warn-tint text-warn-ink rounded-lg border px-3 py-2 text-[12.5px]">
      {tierCopy('high')}
    </div>
  {/if}

  {#if review.staleBase}
    <div role="alert" class="border-warn-border bg-warn-tint text-warn-ink rounded-lg border px-3 py-2 text-[12.5px]">
      This page changed since the update was proposed — approving will be refused; reject it or re-run the workflow.
    </div>
  {/if}

  <div class="border-paper-border bg-paper-card overflow-hidden rounded-xl border">
    {#if !review.isCreate && page === null}
      <p class="text-ink-meta px-3 py-2 text-[11.5px] italic">
        Could not read the current page — showing the proposed content.
      </p>
    {/if}
    <DiffBlock rows={review.rows} truncated={review.truncated} modeLabel={review.isCreate ? 'New page content' : undefined} />
  </div>

  {#if status === 'approved'}
    <p class="text-ink-meta text-[12.5px]">
      Applied to <span class="font-mono text-[11.5px]">{review.targetPath}</span>
      {#if appliedHref}
        · <a href={appliedHref} class="text-act hover:text-act-hover font-semibold">Open in Knowledge &rarr;</a>
      {/if}
      {actedAt ? `· ${formatTime(actedAt)}` : ''}
    </p>
  {:else if status === 'rejected'}
    <p class="text-ink-meta text-[12.5px]">Not applied · {actedAt ? formatTime(actedAt) : ''}</p>
  {:else if status === 'changed'}
    <div
      class="border-suggest-border bg-suggest-bg flex items-center justify-between gap-4 rounded-xl border px-4 py-3"
    >
      <p class="text-suggest-ink text-[13px]">This item changed since you opened it.</p>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onclick={() => {
          status = 'idle';
          onReload();
        }}
      >
        Reload
      </Button>
    </div>
  {:else if status === 'gone'}
    <div class="border-paper-hairline flex items-center justify-between gap-4 border-t px-1 py-3">
      <p class="text-ink-meta text-[13px]">Already handled.</p>
      <a href="/" class="text-act hover:text-act-hover text-[12.5px] font-semibold">Back to Today &rarr;</a>
    </div>
  {:else if status === 'conflict'}
    <div
      class="border-warn-border bg-warn-tint flex items-center justify-between gap-4 rounded-xl border px-4 py-3"
    >
      <p class="text-warn-ink text-[13px]">
        The page changed since this was proposed. The item is back in your queue — reject it or re-run the
        workflow.
      </p>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onclick={() => {
          status = 'idle';
          onReload();
        }}
      >
        Reload
      </Button>
    </div>
  {:else}
    <div class="flex flex-wrap items-center gap-2 pt-1">
      <Button type="button" disabled={status === 'busy'} onclick={() => void approve()}>
        Approve — update the page
      </Button>
      <Input
        type="text"
        bind:value={reason}
        disabled={status === 'busy'}
        placeholder="Why? Optional — this teaches your assistant."
        class="h-8 max-w-[280px]"
      />
      <Button type="button" variant="outline" disabled={status === 'busy'} onclick={() => void reject()}>
        Don't apply this
      </Button>
      {#if errorMessage}
        <p class="text-warn-ink text-[12.5px]" role="alert">{errorMessage}</p>
      {/if}
    </div>
  {/if}
</div>
