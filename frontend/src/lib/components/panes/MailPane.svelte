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
  import { onMount, untrack } from 'svelte';
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import MessageView from '$lib/components/mail/MessageView.svelte';
  import { targetAccount } from '$lib/components/mail/mail-shapes';
  import { mailStore, type MailMessageDetail } from '$lib/stores/mail.svelte';
  import type { PaneContext } from '$lib/panes/context';
  import type { MailPaneDescriptor } from '$lib/panes/pane-route';

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

  /**
   * Account switch then message load, in that order and in ONE effect, with
   * the later of two overlapping loads winning. Lifted from `/mail`'s own
   * selection effect, whose reasoning applies here unchanged:
   *
   * - `select()` writes the shared `mailStore.selected` singleton with no
   *   per-call id tag, so two in-flight loads (fast clicking down the list)
   *   can resolve out of order. `cancelled` drops the stale one instead of
   *   flashing the wrong message body.
   * - `mailStore.selected !== before` is the only available signal for "the
   *   fetch actually landed" versus "it failed and left the old value alone"
   *   (`select` returns `Promise<void>` and early-exits on failure).
   * - Both `mailStore.selected` reads are UNTRACKED: this effect's own
   *   `select()` is what later mutates it, so a tracked read would re-trigger
   *   the effect — an endless `get_mail_message` loop keyed on nothing the
   *   user did.
   * - `targetAccount`'s membership SCAN is untracked too. It reads every row,
   *   and a `mail_status` push replaces rows several times a poll cycle
   *   without changing which accounts exist; tracking it re-ran the whole
   *   effect (and re-fetched the open message) on a screen nobody touched.
   *   `accounts.length` stays the arrived-signal.
   *
   * `selectAccount` and `select` are MailStore's existing methods
   * (mail.svelte.ts:644, 809) — there is no `openMessage`.
   */
  let activeId: string | null = $state(null);
  let activeDetail: MailMessageDetail | null = $state(null);
  let loadError = $state(false);

  $effect(() => {
    const id = descriptor.msgId;
    const wanted = account;
    const storeAccount = mailStore.selectedAccount;
    const accountsReady = mailStore.accounts.length > 0;
    const target = untrack(() => targetAccount(wanted, storeAccount, mailStore.accounts));
    activeId = null;
    activeDetail = null;
    loadError = false;

    let cancelled = false;
    void (async () => {
      if (target && target !== storeAccount) {
        await mailStore.selectAccount(target);
        if (cancelled) return;
      }
      if (!id) return;
      if (!target) {
        if (accountsReady) loadError = true; // accounts loaded, none selectable
        return; // otherwise wait — the effect re-runs when accounts arrive
      }
      const before = untrack(() => mailStore.selected);
      await mailStore.select(id);
      if (cancelled) return;
      const selected = untrack(() => mailStore.selected);
      if (selected !== before) {
        activeId = id;
        activeDetail = selected;
      } else {
        loadError = true;
      }
    })();

    return () => {
      cancelled = true;
    };
  });
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
    {:else if activeId === descriptor.msgId && activeDetail}
      <MessageView message={activeDetail} />
    {:else if loadError}
      <p class="text-warn-ink text-[13px]" role="alert">This message could not be loaded.</p>
    {:else}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {/if}
  </div>
</div>
