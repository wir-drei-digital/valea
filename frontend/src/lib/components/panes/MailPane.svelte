<script lang="ts">
  /**
   * The mail READ SURFACE — account-scoped message list plus the open message.
   * Deliberately not the whole route: compose, drafts and setup are
   * full-screen tasks, not things you glance at beside a transcript, and they
   * stay in `/mail`.
   *
   * Selection arrives as callbacks rather than hrefs so one implementation
   * serves both hosts: the route passes a `goto`, a pane passes a descriptor
   * rewrite. Same shape `PaneContext.openFile` already uses.
   */
  import { onMount } from 'svelte';
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import MessageView from '$lib/components/mail/MessageView.svelte';
  import { watchMailSelection } from '$lib/components/mail/mail-selection.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import type { PaneContext } from '$lib/panes/context';
  import type { MailPaneDescriptor, PaneDescriptor } from '$lib/panes/pane-route';

  let {
    descriptor,
    context
  }: { descriptor: MailPaneDescriptor; context: PaneContext } = $props();

  // Availability is only ever asserted from LOADED data: `mailStore.accounts`
  // starts empty, so "no account" must not be concluded before a fetch.
  const known = $derived(mailStore.statusLoaded);
  const account = $derived(descriptor.account);

  // A pane can be the ONLY mail surface on screen (mail beside a transcript on
  // `/chat`), and nothing else would have asked. Guarded on `statusLoaded` so
  // mounting beside a route that already fetched costs nothing.
  onMount(() => {
    if (!mailStore.statusLoaded) void mailStore.refreshStatus();
  });

  // The account-switch-then-load effect, shared verbatim with `/mail` — see
  // `mail-selection.svelte.ts` for why every `untrack` in it is load-bearing.
  // The two hosts differ only in where the selection comes from: a descriptor
  // here, `?message=`/`?account=` there.
  const selection = watchMailSelection(() => ({ msgId: descriptor.msgId, account }));

  // A message can start a session BESIDE itself from a pane too — same append,
  // same refusal as on the route, because the host answers both. A host that
  // offers no append at all is its own reason: the alternative is a button that
  // creates a real session and puts it nowhere.
  //
  // Passed as a function so the KIND comes from the descriptor `MessageView`
  // will open rather than from a guess made here — see the prop's note.
  const sessionRefusal = (kind: PaneDescriptor['kind']): string | null =>
    context.openBeside
      ? (context.besideRefusal?.(kind) ?? null)
      : 'This view cannot open a session beside it';
</script>

<div class="flex min-h-0 min-w-0 flex-1">
  <div class="border-paper-hairline w-[260px] shrink-0 overflow-y-auto border-r">
    {#if known && mailStore.accounts.length === 0}
      <p class="text-ink-meta px-3.5 py-3 text-[12.5px]">No mail account yet. Add one in Sources.</p>
    {:else}
      <!-- The rows belong to whichever account the STORE is reading, so that
           is the account a row hands back — the descriptor's slug can be one
           `targetAccount` rejected. -->
      <MessageList
        account={mailStore.selectedAccount ?? account}
        messages={mailStore.messages}
        selectedId={descriptor.msgId}
        onSelect={(acct, msgId) => context.openPane?.({ ...descriptor, account: acct, msgId })}
      />
    {/if}
  </div>
  <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
    {#if !descriptor.msgId}
      <p class="text-ink-meta text-[12.5px]">Pick a message to read it.</p>
    {:else if selection.activeId === descriptor.msgId && selection.detail}
      <MessageView
        message={selection.detail}
        onStartSessionBeside={(d) => context.openBeside?.(d)}
        besideRefusal={sessionRefusal}
      />
    {:else if selection.failed}
      <p class="text-warn-ink text-[13px]" role="alert">This message could not be loaded.</p>
    {:else}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {/if}
  </div>
</div>
