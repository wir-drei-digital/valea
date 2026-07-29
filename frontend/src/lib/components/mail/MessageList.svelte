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
  //
  // Rows carry the `account` they belong to into their href (`messageHref`):
  // a `msgId` only identifies a message WITHIN an account, so an unqualified
  // link resolves against whichever account is selected when it's opened.
  //
  // Search hits (`search_mail`) render through this same list rather than a
  // fork of it: the action returns the identical per-row shape plus
  // `snippet`, so a row that CARRIES one gets a third line for it under the
  // subject — the subject stays, because "which message is this" is the
  // first thing a result has to answer. A folder listing carries no
  // snippets, so nothing changes there.
  //
  // The snippet is mail body text: it renders as plain interpolation
  // (Svelte-escaped), never `{@html}`, and the backend sends no highlight
  // markers precisely so that nothing here has to.
  //
  // A FOLDER listing arrives collapsed by conversation (Task 11): the row is
  // the thread's newest message, and a multi-message thread carries a count
  // badge beside the time. Search hits arrive flat and carry no count, so the
  // badge simply never renders for them — one component, both listings, the
  // same additive pattern the snippet line uses. Clicking a collapsed row
  // opens its newest message; the read pane's strip is where the rest of the
  // conversation is.
  import {
    fromLabel,
    subjectLabel,
    relativeTime,
    listRowKey,
    messageHref,
    threadCountBadge,
    threadUnread
  } from './mail-shapes';
  import type { MailMessageSummary } from '$lib/stores/mail.svelte';

  let {
    messages,
    selectedId,
    account,
    density = 'comfortable',
    showSnippets = true
  }: {
    messages: (MailMessageSummary & { snippet?: string })[];
    selectedId: string | null;
    account: string;
    /** Row rhythm — `compact` tightens the vertical padding for dense embeddings. */
    density?: 'comfortable' | 'compact';
    /** Whether a row that carries a `snippet` renders its snippet line. */
    showSnippets?: boolean;
  } = $props();
</script>

<ul class="divide-paper-hairline flex flex-col divide-y">
  {#each messages as message (listRowKey(message))}
    {@const selected = message.msgId === selectedId}
    {@const threadCount = threadCountBadge(message)}
    <li>
      <a
        href={messageHref(account, message.msgId)}
        class="block border-l-[3px] pr-4 pl-3.5 transition-colors hover:bg-paper-pill"
        class:py-3={density === 'comfortable'}
        class:py-2={density === 'compact'}
        class:border-act={selected}
        class:border-transparent={!selected}
        class:bg-paper-card={selected}
      >
        <span class="flex items-baseline justify-between gap-3">
          <span class="flex min-w-0 items-baseline gap-1.5">
            {#if threadUnread(message)}
              <span class="bg-act size-1.5 shrink-0 self-center rounded-full" title="Unread" aria-label="Unread"
              ></span>
            {/if}
            <span class="text-ink-heading min-w-0 truncate text-[13.5px] [font-weight:650]">{fromLabel(message)}</span>
          </span>
          <span class="flex shrink-0 items-baseline gap-1.5">
            {#if threadCount}
              <span
                class="bg-paper-track text-ink-meta rounded-full px-1.5 text-[10.5px] [font-weight:650] tabular-nums"
                title="Conversation: {threadCount} messages in this folder"
                aria-label="Conversation: {threadCount} messages in this folder"
              >
                {threadCount}
              </span>
            {/if}
            <span class="text-ink-meta text-[11.5px]">{relativeTime(message.date)}</span>
          </span>
        </span>
        <span class="text-ink-body mt-0.5 block truncate text-[13px]">{subjectLabel(message.subject)}</span>
        {#if showSnippets && message.snippet}
          <span class="text-ink-meta mt-0.5 block truncate text-[12px]">{message.snippet}</span>
        {/if}
      </a>
    </li>
  {/each}
</ul>
