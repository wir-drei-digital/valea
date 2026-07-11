<script lang="ts">
  // Indexed mail messages (docs/DESIGN_SYSTEM.md §8 "Mail list item —
  // selected = #FFFEFA fill + 3px green left bar. Status badges show the
  // assistant's work at a glance."). `messages` is the FULL indexed set
  // (`Valea.Mail.Store.list_messages/0` returns every row, "review" and
  // "processed" alike, newest date first) — the dot distinguishes the two,
  // it does not filter the list. Rows link to `?message=<msgId>`, mirroring
  // `chat/+page.svelte`'s `?session=<id>` selection pattern.
  import { messageDot, MESSAGE_DOT_CLASS, isProcessed, fromLabel, subjectLabel, relativeTime } from './mail-shapes';
  import type { MailMessageSummary } from '$lib/stores/mail.svelte';

  let { messages, selectedId }: { messages: MailMessageSummary[]; selectedId: string | null } = $props();
</script>

<ul class="flex flex-col">
  {#each messages as message (message.msgId)}
    {@const selected = message.msgId === selectedId}
    {@const processed = isProcessed(message.status)}
    <li>
      <a
        href={`/mail?message=${encodeURIComponent(message.msgId)}`}
        class="flex items-start gap-2 border-l-[3px] py-2.5 pr-3 pl-2.5 text-[13px] transition-colors hover:bg-paper-pill"
        class:border-act={selected}
        class:border-transparent={!selected}
        class:bg-paper-card={selected}
        class:opacity-70={processed && !selected}
      >
        <span
          class="mt-1.5 size-1.5 shrink-0 rounded-full {MESSAGE_DOT_CLASS[messageDot(message.status)]}"
          aria-hidden="true"
        ></span>
        <span class="min-w-0 flex-1">
          <span class="text-ink-heading block truncate [font-weight:650]">{fromLabel(message)}</span>
          <span class="text-ink-body block truncate">{subjectLabel(message.subject)}</span>
        </span>
        <span class="text-ink-meta shrink-0 pt-px text-[11px]">{relativeTime(message.date)}</span>
      </a>
    </li>
  {/each}
</ul>
