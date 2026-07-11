<script lang="ts">
  // Collapsed-by-default raw IMAP inbox cache (`Store.inbox_headers()`,
  // `mailStore.inbox`) — header rows only, no actions: these are cached
  // mailbox headers, not the indexed files `MessageList` links to, so
  // there's nowhere for a click here to go this phase. Collapse affordance
  // mirrors `agent/PlanBar.svelte`'s button + chevron pattern; count badge
  // is plain `text-ink-meta` per DESIGN_SYSTEM §5 ("plain #948a75 text for
  // neutral counts" — this isn't a "things waiting" or suggestion count).
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import ChevronUp from '@lucide/svelte/icons/chevron-up';
  import { nonEmpty, relativeTime } from './mail-shapes';
  import type { InboxEntry } from '$lib/stores/mail.svelte';

  let { entries }: { entries: InboxEntry[] } = $props();

  let expanded = $state(false);
</script>

<div class="border-paper-hairline border-t px-2.5 py-2">
  <button
    type="button"
    onclick={() => (expanded = !expanded)}
    class="flex w-full items-center gap-2 py-1 text-left"
  >
    <span class="text-overline">Inbox</span>
    <span class="text-ink-meta text-[11px]">{entries.length}</span>
    <span class="flex-1"></span>
    {#if expanded}
      <ChevronUp class="text-ink-meta size-3.5 shrink-0" aria-hidden="true" />
    {:else}
      <ChevronDown class="text-ink-meta size-3.5 shrink-0" aria-hidden="true" />
    {/if}
  </button>

  {#if expanded}
    <ul class="mt-1 flex flex-col">
      {#each entries as entry (entry.uid)}
        <li class="flex items-center gap-2 py-1.5 text-[12px] opacity-80">
          <span class="text-ink-secondary min-w-0 flex-1 truncate">{nonEmpty(entry.fromText, '(unknown sender)')}</span>
          <span class="text-ink-meta min-w-0 flex-1 truncate">{nonEmpty(entry.subject, '(no subject)')}</span>
          <span class="text-ink-meta shrink-0 text-[11px]">{relativeTime(entry.date)}</span>
        </li>
      {:else}
        <li class="text-ink-meta py-1.5 text-[12px]">Nothing cached yet.</li>
      {/each}
    </ul>
  {/if}
</div>
