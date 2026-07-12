<script lang="ts">
  // Raw IMAP inbox cache (`Store.inbox_headers()`, `mailStore.inbox`) —
  // header rows only, no actions: these are cached mailbox headers, not the
  // indexed files `MessageList` links to, so there's nowhere for a click
  // here to go this phase. Shown when the pane's "Inbox" filter pill is
  // active (the pill row in `mail/+page.svelte` replaced the old inline
  // collapse toggle); count badge stays plain per DESIGN_SYSTEM §5 ("plain
  // #948a75 text for neutral counts" — this isn't a "things waiting" or
  // suggestion count).
  import { nonEmpty, relativeTime } from './mail-shapes';
  import type { InboxEntry } from '$lib/stores/mail.svelte';

  let { entries }: { entries: InboxEntry[] } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each entries as entry (entry.uid)}
    <li class="py-3 pr-4 pl-[17px]">
      <span class="flex items-baseline justify-between gap-3">
        <span class="text-ink-secondary min-w-0 truncate text-[13.5px] font-medium"
          >{nonEmpty(entry.fromText, '(unknown sender)')}</span
        >
        <span class="text-ink-meta shrink-0 text-[11.5px]">{relativeTime(entry.date)}</span>
      </span>
      <span class="text-ink-meta mt-0.5 block truncate text-[13px]">{nonEmpty(entry.subject, '(no subject)')}</span>
    </li>
  {:else}
    <li class="text-ink-meta px-4 py-3 text-[12.5px]">Nothing cached yet.</li>
  {/each}
</ul>
