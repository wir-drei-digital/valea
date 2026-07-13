<script lang="ts">
  // Full-draft review — the ONLY place approval happens (docs/DESIGN_SYSTEM.md
  // §6/§8/§10). To/Subject as label/value rows (§8 "structured facts": label
  // `text-ink-meta`, value 600-weight ink — same convention as
  // `editor/PageMeta.svelte`'s Contract rows). Body renders as plain
  // preformatted TEXT — `white-space: pre-wrap`, body font, NOT mono, NOT
  // markdown-rendered, and NEVER `{@html}` — it's untrusted agent output,
  // interpolated the same inert way as `PermissionCard`'s `command`.
  // Reasoning is a verbatim quote in italic serif (§10 "rail cards": "italic
  // serif quote (verbatim only)").
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { queueStore } from '$lib/stores/queue.svelte';
  import type { QueueItemEnvelope } from '$lib/api/client';
  import QueueSourceChips from './QueueSourceChips.svelte';

  let {
    item,
    revision,
    runId,
    onReload
  }: {
    item: QueueItemEnvelope;
    revision: string;
    runId: string;
    /** Re-fetches `item`/`revision` from the parent route — see its "changed" reload path. */
    onReload: () => void;
  } = $props();

  type ProposedAction = { to?: unknown; subject?: unknown; body_markdown?: unknown };
  type Payload = {
    title?: unknown;
    summary?: unknown;
    sources?: unknown;
    reasoning?: unknown;
    proposed_action?: unknown;
  };

  const payload = $derived((item.payload ?? {}) as Payload);
  const title = $derived(typeof payload.title === 'string' ? payload.title : 'Untitled draft');
  const summary = $derived(typeof payload.summary === 'string' ? payload.summary : '');
  const reasoning = $derived(typeof payload.reasoning === 'string' ? payload.reasoning : '');
  const sources = $derived(
    Array.isArray(payload.sources) ? payload.sources.filter((s): s is string => typeof s === 'string') : []
  );
  const action = $derived((payload.proposed_action ?? {}) as ProposedAction);
  const to = $derived(typeof action.to === 'string' ? action.to : '');
  const subject = $derived(typeof action.subject === 'string' ? action.subject : '');
  const body = $derived(typeof action.body_markdown === 'string' ? action.body_markdown : '');

  // Deterministic — mirrors `Valea.Queue.draft_rel_path/1` exactly (see
  // queue.ex: `Path.join(["sources", "mail", "drafts", run_id <> ".md"])`).
  // The approve RPC does hand back the real `draftPath`, but `QueueStore`
  // (T16) intentionally narrows its `approve/2` return to `{ok:true}` on
  // success — reusing the store here keeps generation-sourcing and the
  // queue-list refetch (so Today drops the ApprovalCard once this item
  // leaves `pending/`) in one place rather than duplicating them against
  // the raw `api.approveQueueItem` call.
  const draftPath = $derived(`sources/mail/drafts/${runId}.md`);

  type Status = 'idle' | 'busy' | 'approved' | 'rejected' | 'changed' | 'gone' | 'error';
  let status: Status = $state('idle');
  let errorMessage: string | null = $state(null);
  let actedAt: Date | null = $state(null);
  // Optional skippable reject reason (B6/B12) — the queue's teaching signal,
  // see docs/superpowers/specs/2026-07-12-methodology-depth-design.md §5.
  let reason = $state('');

  function describeError(code: string): string {
    switch (code) {
      case 'queue_item_changed':
        return 'changed';
      case 'queue_item_gone':
        return 'gone';
      case 'workspace_not_open':
        return 'No workspace is open.';
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'apply_conflict':
        return 'The page changed since this was proposed. The item is back in your queue — reject it or re-run the workflow.';
      default:
        return 'Something went wrong. Please try again.';
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
    const mapped = describeError(result.error);
    if (mapped === 'changed') {
      status = 'changed';
    } else if (mapped === 'gone') {
      status = 'gone';
    } else {
      status = 'error';
      errorMessage = mapped;
    }
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
    const mapped = describeError(result.error);
    if (mapped === 'changed') {
      status = 'changed';
    } else if (mapped === 'gone') {
      status = 'gone';
    } else {
      status = 'error';
      errorMessage = mapped;
    }
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
      Reply drafted
    </span>
    <h1 class="font-display text-ink-heading text-[24px] leading-tight font-medium">{title}</h1>
    <p class="text-ink-body text-[13.5px]">{summary}</p>
  </header>

  <dl class="border-paper-hairline divide-paper-hairline flex flex-col divide-y rounded-lg border">
    <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
      <dt class="text-ink-meta shrink-0">To</dt>
      <dd class="text-ink-heading truncate text-right font-semibold">{to}</dd>
    </div>
    <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
      <dt class="text-ink-meta shrink-0">Subject</dt>
      <dd class="text-ink-heading truncate text-right font-semibold">{subject}</dd>
    </div>
  </dl>

  <div class="border-paper-border bg-paper-card rounded-xl border px-5 py-4">
    <p class="text-ink-body font-sans text-[13.5px] leading-relaxed whitespace-pre-wrap">{body}</p>
  </div>

  {#if sources.length > 0}
    <div>
      <p class="text-overline mb-2">Used</p>
      <QueueSourceChips {sources} />
    </div>
  {/if}

  {#if reasoning}
    <div>
      <p class="text-overline mb-2">Why this draft</p>
      <p class="font-display text-ink-secondary text-[14.5px] leading-relaxed italic">
        &ldquo;{reasoning}&rdquo;
      </p>
    </div>
  {/if}

  {#if status === 'approved'}
    <p class="text-ink-meta text-[12.5px]">
      In your drafts · {actedAt ? formatTime(actedAt) : ''} ·
      <span class="font-mono text-[11.5px]">{draftPath}</span>
    </p>
  {:else if status === 'rejected'}
    <p class="text-ink-meta text-[12.5px]">Not sent · {actedAt ? formatTime(actedAt) : ''}</p>
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
  {:else}
    <div class="flex flex-wrap items-center gap-2 pt-1">
      <Button type="button" disabled={status === 'busy'} onclick={() => void approve()}>
        Approve — put in my drafts
      </Button>
      <Input
        type="text"
        bind:value={reason}
        disabled={status === 'busy'}
        placeholder="Why? Optional — this teaches your assistant."
        class="h-8 max-w-[280px]"
      />
      <Button type="button" variant="outline" disabled={status === 'busy'} onclick={() => void reject()}>
        Don't send this
      </Button>
      {#if errorMessage}
        <p class="text-warn-ink text-[12.5px]" role="alert">{errorMessage}</p>
      {/if}
    </div>
  {/if}
</div>
