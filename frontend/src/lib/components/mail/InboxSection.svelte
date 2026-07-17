<script lang="ts">
  // INBOX folder listing (`list_mail_messages(account, "INBOX")`,
  // `mailStore.inbox`) — read-only rows, no actions: these mirror the
  // account's raw INBOX, not the `AI/Review` folder `MessageList` links
  // into, so there's nowhere for a click here to go this phase. Shown when
  // the pane's "Inbox" filter pill is active (the pill row in
  // `mail/+page.svelte` replaced the old inline collapse toggle); count
  // badge stays plain per DESIGN_SYSTEM §5 ("plain #948a75 text for neutral
  // counts" — this isn't a "things waiting" or suggestion count).
  //
  // Task 10: the old `mail_inbox` action (a separate raw IMAP-header cache)
  // is gone — this reuses `MessageList`'s `MailMessageSummary` shape (same
  // `fromName`/`fromEmail`/`subject`/`date` fields the account-scoped
  // `list_mail_messages` action returns for any folder) via `fromLabel`,
  // rather than the old single-string `fromText`.
  import { fromLabel, subjectLabel, relativeTime } from './mail-shapes';
  import type { MailMessageSummary } from '$lib/stores/mail.svelte';

  let { entries }: { entries: MailMessageSummary[] } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each entries as entry (entry.msgId)}
    <li class="py-3 pr-4 pl-[17px]">
      <span class="flex items-baseline justify-between gap-3">
        <span class="text-ink-secondary min-w-0 truncate text-[13.5px] font-medium">{fromLabel(entry)}</span>
        <span class="text-ink-meta shrink-0 text-[11.5px]">{relativeTime(entry.date)}</span>
      </span>
      <span class="text-ink-meta mt-0.5 block truncate text-[13px]">{subjectLabel(entry.subject)}</span>
    </li>
  {:else}
    <li class="text-ink-meta px-4 py-3 text-[12.5px]">Nothing cached yet.</li>
  {/each}
</ul>
