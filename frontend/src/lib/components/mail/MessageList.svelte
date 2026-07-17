<script lang="ts">
  // Indexed mail messages (docs/DESIGN_SYSTEM.md §8 "Mail list item —
  // selected = #FFFEFA fill + 3px green left bar. Status badges show the
  // assistant's work at a glance."). `messages` is the account's `AI/Review`
  // folder listing (`list_mail_messages(account, "AI/Review")`, newest date
  // first — Task 10's account-scoped rework; the old flat "review"/
  // "processed" status marker is gone, so `messageDot`/`isProcessed`
  // currently render every row the same way — see their doc comments in
  // `mail-shapes.ts`). Rows link to `?message=<msgId>`, mirroring
  // `chat/+page.svelte`'s `?session=<id>` selection pattern.
  //
  // Row anatomy per the cockpit screens: sender line (650) with the
  // relative time right-aligned, subject line under it, hairline dividers
  // between rows.
  import { messageDot, MESSAGE_DOT_CLASS, isProcessed, fromLabel, subjectLabel, relativeTime } from './mail-shapes';
  import type { MailMessageSummary } from '$lib/stores/mail.svelte';

  let { messages, selectedId }: { messages: MailMessageSummary[]; selectedId: string | null } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each messages as message (message.msgId)}
    {@const selected = message.msgId === selectedId}
    {@const processed = isProcessed(message.flags)}
    <li>
      <a
        href={`/mail?message=${encodeURIComponent(message.msgId)}`}
        class="block border-l-[3px] py-3 pr-4 pl-3.5 transition-colors hover:bg-paper-pill"
        class:border-act={selected}
        class:border-transparent={!selected}
        class:bg-paper-card={selected}
        class:opacity-70={processed && !selected}
      >
        <span class="flex items-baseline justify-between gap-3">
          <span class="flex min-w-0 items-center gap-1.5">
            <span
              class="size-1.5 shrink-0 rounded-full {MESSAGE_DOT_CLASS[messageDot(message.flags)]}"
              aria-hidden="true"
            ></span>
            <span class="text-ink-heading truncate text-[13.5px] [font-weight:650]">{fromLabel(message)}</span>
          </span>
          <span class="text-ink-meta shrink-0 text-[11.5px]">{relativeTime(message.date)}</span>
        </span>
        <span class="text-ink-body mt-0.5 block truncate pl-3 text-[13px]">{subjectLabel(message.subject)}</span>
      </a>
    </li>
  {/each}
</ul>
