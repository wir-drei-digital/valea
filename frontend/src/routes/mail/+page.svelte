<script lang="ts">
  // Mail route (spec Task 16): indexed messages + collapsed raw inbox +
  // sync status in the list pane, read pane + "Run triage" in main.
  // Composed the same way as `/chat` (AppFrame + ListPane), with
  // `?message=<msg_id>` selection instead of `?session=<id>` — mail
  // messages aren't part of the ICM file tree either, so a query param
  // (not a path segment) is the right selection mechanism here too.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { onMount, untrack } from 'svelte';
  import { AppFrame, ListPane, EmptyState } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import MailIcon from '@lucide/svelte/icons/mail';
  import { mailStore, type MailMessageDetail } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import InboxSection from '$lib/components/mail/InboxSection.svelte';
  import SyncStatusLine from '$lib/components/mail/SyncStatusLine.svelte';
  import MessageView from '$lib/components/mail/MessageView.svelte';

  // `mail_status`/`mail_sync`/`mail_message`/`mailbox_ops` are wired ONCE,
  // at the layout (`wireMailEvents`, called from `wireIcmEvents` in
  // `icm.svelte.ts`'s single `workspace:events` join site — see that
  // function's doc comment for why this route must not join a second
  // channel itself). This mount just does the route's own initial reads;
  // `refreshStatus()`'s success path also triggers the desktop-only
  // keychain credential resupply as a side effect (see
  // `MailStore#applyStatus` → `resupplyCredential` in `mail.svelte.ts`) —
  // no separate call needed here.
  onMount(() => {
    void mailStore.refreshStatus();
    void mailStore.refreshMessages();
    void mailStore.refreshInbox();
  });

  const selectedId = $derived(page.url.searchParams.get('message'));
  const setupRequested = $derived(page.url.searchParams.get('setup') === '1');

  // Race-safe selection load: `MailStore.select` writes into the shared
  // `mailStore.selected` singleton with no per-call id tag, so two
  // in-flight `select()` calls (rapid clicking between messages) could
  // otherwise resolve out of order. `activeId`/`activeDetail` are this
  // route's own local capture of "the detail that belongs to the
  // currently-selected id" — read synchronously off `mailStore.selected`
  // the instant THIS call's own `select()` resolves (safe: `select()`'s
  // last statement before returning is exactly the assignment this reads,
  // so no other concurrent call's completion can interleave in between —
  // see `MailStore.select` in `mail.svelte.ts`), and only committed if a
  // newer selection hasn't superseded it (`cancelled`) — a stale, slower
  // response for a message the user has since navigated away from is
  // silently dropped rather than flashing the wrong content.
  //
  // `mailStore.selected !== before` distinguishes "the fetch actually
  // updated `selected`" from "it failed and left the old value alone" (see
  // `MailStore.select`'s `if (!result.ok) return;` early exit) — `select()`
  // returns `Promise<void>`, so reference identity is the only signal
  // available for that distinction without changing the store's contract.
  //
  // `untrack` around both `mailStore.selected` reads is load-bearing, not
  // decorative: this effect's own `select()` call is what LATER mutates
  // `mailStore.selected`. Reading it un-tracked inside the effect body
  // would register it as a dependency, so that later mutation would
  // re-trigger this same effect — which reassigns `before`, fires ANOTHER
  // `select()`, mutates `selected` again, re-triggers again — an infinite
  // `get_mail_message` loop keyed on nothing the user did (caught live:
  // the backend log showed the identical RPC firing hundreds of times a
  // second). The effect must only re-run when `selectedId` (the URL param)
  // changes, never as a side effect of its own fetch completing.
  let activeId: string | null = $state(null);
  let activeDetail: MailMessageDetail | null = $state(null);
  let loadError = $state(false);

  $effect(() => {
    const id = selectedId;
    activeId = null;
    activeDetail = null;
    loadError = false;
    if (!id) return;

    let cancelled = false;
    const before = untrack(() => mailStore.selected);
    void mailStore.select(id).then(() => {
      if (cancelled) return;
      const selected = untrack(() => mailStore.selected);
      if (selected !== before) {
        activeId = id;
        activeDetail = selected;
      } else {
        loadError = true;
      }
    });

    return () => {
      cancelled = true;
    };
  });

  function syncNow(): Promise<string | null> {
    return mailStore.syncNow(workspaceStore.generation ?? 0);
  }
</script>

<AppFrame>
  {#snippet list()}
    <ListPane>
      {#snippet header()}
        <p class="text-overline">Mail</p>
      {/snippet}
      {#snippet children()}
        <MessageList messages={mailStore.messages} {selectedId} />
        <InboxSection entries={mailStore.inbox} />
      {/snippet}
      {#snippet footer()}
        <SyncStatusLine status={mailStore.status} onSyncNow={syncNow} />
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if setupRequested}
      <div class="flex flex-col items-start gap-3 py-10">
        <p class="text-overline">Mail</p>
        <h1 class="font-display text-ink-heading text-[21px]">Connect your mailbox</h1>
        <p class="text-ink-body max-w-[480px] text-[13.5px]">Account setup arrives with the next task.</p>
        <a href="/mail" class="text-act hover:text-act-hover text-[12.5px] font-semibold">Back &rarr;</a>
      </div>
    {:else if !selectedId}
      <EmptyState icon={MailIcon} title="Mail" body="Messages you move to AI/Review appear here.">
        {#snippet actions()}
          {#if mailStore.status && !mailStore.status.configured}
            <Button type="button" onclick={() => void goto('/mail?setup=1')}>Connect your mailbox</Button>
          {/if}
        {/snippet}
      </EmptyState>
    {:else if activeId === selectedId && activeDetail}
      <MessageView message={activeDetail} />
    {:else if loadError}
      <p class="text-warn-ink text-[13px]" role="alert">This message could not be loaded.</p>
    {:else}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {/if}
  {/snippet}
</AppFrame>
