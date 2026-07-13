<script lang="ts">
  // Approval-family summary card (docs/DESIGN_SYSTEM.md §6): kind badge →
  // title → summary → source chips → actions. Shared anatomy with
  // `today/PreparedItemCard.svelte`, but with exactly ONE primary action —
  // approval is NEVER available from the summary card, only from the full
  // draft review route (`/queue/[run_id]`, see DraftReview.svelte). "Review
  // the draft →" is a green LINK action (§4: link actions get a `→`, never
  // a filled button), not "Approve" — clicking it never sends anything.
  import type { QueueItemEnvelope } from '$lib/api/client';
  import QueueSourceChips from './QueueSourceChips.svelte';

  let { item }: { item: QueueItemEnvelope } = $props();

  type Payload = { title?: unknown; summary?: unknown; sources?: unknown; kind?: unknown };

  const payload = $derived((item.payload ?? {}) as Payload);
  const title = $derived(typeof payload.title === 'string' ? payload.title : 'Untitled draft');
  const summary = $derived(typeof payload.summary === 'string' ? payload.summary : '');
  const sources = $derived(
    Array.isArray(payload.sources) ? payload.sources.filter((s): s is string => typeof s === 'string') : []
  );
  // B12: a `memory_update` item gets its own badge/link copy — approving it
  // edits a mount page, not sending an email — but shares this card's
  // anatomy and its single "review, never approve here" link action.
  const isMemoryUpdate = $derived(payload.kind === 'memory_update');

  // Kind-aware: nothing "goes out" for a memory_update — it edits a mount
  // page, so the hint says so instead of carrying the email-only framing
  // over unchanged.
  const riskHint = $derived.by(() => {
    if (isMemoryUpdate) {
      switch (item.risk_level) {
        case 'high':
          return 'Higher risk — worth a careful read before it changes your assistant.';
        case 'medium':
          return 'Medium risk — a quick read before it updates your memory.';
        case 'low':
          return 'Low risk.';
        default:
          return null;
      }
    }
    switch (item.risk_level) {
      case 'high':
        return 'Higher risk — worth a careful read before it goes out.';
      case 'medium':
        return 'Medium risk — a quick read before it goes out.';
      case 'low':
        return 'Low risk.';
      default:
        return null;
    }
  });
</script>

<article
  class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2.5 rounded-xl border px-5 py-[18px]"
>
  <span
    class="bg-act-tint text-act inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
  >
    {isMemoryUpdate ? 'Memory update suggested' : 'Reply drafted'}
  </span>

  <h3 class="text-ink-heading text-[14.5px] [font-weight:650]">{title}</h3>

  <p class="text-ink-body text-[13.5px] leading-normal">{summary}</p>

  <QueueSourceChips {sources} />

  {#if riskHint}
    <p class="text-ink-meta text-[12px]">{riskHint}</p>
  {/if}

  <div class="flex flex-wrap items-center gap-2 pt-0.5">
    <a
      href={`/queue/${item.run_id}`}
      class="text-act hover:text-act-hover text-[13px] font-semibold"
    >
      {isMemoryUpdate ? 'Review the change →' : 'Review the draft →'}
    </a>
    <a
      href={`/chat?session=${item.session_id}`}
      class="text-ink-secondary hover:text-ink-heading ml-auto self-end text-[12.5px]"
    >
      Why this? &rarr;
    </a>
  </div>
</article>
