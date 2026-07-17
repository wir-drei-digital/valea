<script lang="ts">
  // Indexed mail messages (docs/DESIGN_SYSTEM.md §8: "Mail list item —
  // selected = #FFFEFA fill + 3px green left bar"). `messages` is the
  // selected folder's `list_mail_messages` listing for the selected
  // account, newest date first. Rows link to `?message=<msgId>`, mirroring
  // `chat/+page.svelte`'s `?session=<id>` selection pattern.
  //
  // Row anatomy per the cockpit screens: sender line (650) with the
  // relative time right-aligned, subject line under it, hairline dividers
  // between rows. The old review/processed status dot is gone with the
  // status marker itself — the maildir backend has no per-message workflow
  // state (spec E: flags are IMAP's, not Valea's).
  import { fromLabel, subjectLabel, relativeTime } from './mail-shapes';
  import type { MailMessageSummary } from '$lib/stores/mail.svelte';

  let { messages, selectedId }: { messages: MailMessageSummary[]; selectedId: string | null } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each messages as message (message.msgId)}
    {@const selected = message.msgId === selectedId}
    <li>
      <a
        href={`/mail?message=${encodeURIComponent(message.msgId)}`}
        class="block border-l-[3px] py-3 pr-4 pl-3.5 transition-colors hover:bg-paper-pill"
        class:border-act={selected}
        class:border-transparent={!selected}
        class:bg-paper-card={selected}
      >
        <span class="flex items-baseline justify-between gap-3">
          <span class="text-ink-heading min-w-0 truncate text-[13.5px] [font-weight:650]">{fromLabel(message)}</span>
          <span class="text-ink-meta shrink-0 text-[11.5px]">{relativeTime(message.date)}</span>
        </span>
        <span class="text-ink-body mt-0.5 block truncate text-[13px]">{subjectLabel(message.subject)}</span>
      </a>
    </li>
  {/each}
</ul>
