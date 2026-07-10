<script lang="ts">
  // One dense receipt row (DESIGN_SYSTEM §8: "dense queue / audit rows...
  // never expandable-looking — they're receipts, not tasks"): dot by type →
  // plain sentence → optional transcript/review links → timestamp
  // right-aligned. `sentence(entry)` is the only thing that reads `entry`'s
  // heterogeneous fields; this component just lays out its output.
  //
  // Content here (`sentence(entry)`'s output, ultimately built from agent
  // tool-call titles and workflow/file paths — see that module's doc
  // comment) is UNTRUSTED, same posture as chat transcripts — plain
  // interpolation only, `{@html}` forbidden.
  import type { AuditEntry } from '$lib/api/client';
  import { sentence, auditDot, AUDIT_DOT_CLASS, transcriptHref, reviewHref, formatAuditTimestamp } from './sentence';

  let { entry }: { entry: AuditEntry } = $props();

  const text = $derived(sentence(entry));
  const dot = $derived(auditDot(entry.type));
  const transcript = $derived(transcriptHref(entry));
  const review = $derived(reviewHref(entry));
  const time = $derived(formatAuditTimestamp(entry.ts));
</script>

<div class="border-paper-hairline flex items-start gap-3 border-b py-2.5 last:border-b-0">
  <span class="mt-1.5 size-2 shrink-0 rounded-full {AUDIT_DOT_CLASS[dot]}" aria-hidden="true"></span>
  <p class="text-ink-body min-w-0 flex-1 text-[13px] leading-normal">{text}</p>
  {#if transcript}
    <a href={transcript} class="text-ink-secondary hover:text-ink-heading shrink-0 pt-0.5 text-[12px]">
      transcript &rarr;
    </a>
  {/if}
  {#if review}
    <a href={review} class="text-act hover:text-act-hover shrink-0 pt-0.5 text-[12px] font-semibold">
      review &rarr;
    </a>
  {/if}
  <span class="text-ink-meta shrink-0 pt-0.5 text-[11.5px] tabular-nums">{time}</span>
</div>
