<script lang="ts">
  // Mail route (mail design spec E §UI): account switcher + folder list +
  // the selected folder's messages in the list pane, read pane in main.
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
  import { api } from '$lib/api/client';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import { cleanupPrompt, syncNowErrorMessage } from '$lib/components/mail/mail-shapes';
  import { mailStore, type MailMessageDetail } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import AccountSwitcher from '$lib/components/mail/AccountSwitcher.svelte';
  import DraftsPanel from '$lib/components/mail/DraftsPanel.svelte';
  import FolderList from '$lib/components/mail/FolderList.svelte';
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import SyncStatusLine from '$lib/components/mail/SyncStatusLine.svelte';
  import MessageView from '$lib/components/mail/MessageView.svelte';
  import SetupPanel from '$lib/components/mail/SetupPanel.svelte';

  // `mail_status`/`mail_sync`/`mail_message` are wired ONCE, at the layout
  // (`wireMailEvents`, called from `wireIcmEvents` in `icm.svelte.ts`'s
  // single `workspace:events` join site — see that function's doc comment
  // for why this route must not join a second channel itself). This mount
  // just does the route's own initial read; `refreshStatus()` defaults the
  // account selection and kicks off the folder/message loads itself
  // (`MailStore#ensureSelection`), and its success path also triggers the
  // desktop-only keychain credential resupply as a side effect.
  onMount(() => {
    void mailStore.refreshStatus();
    void mailStore.refreshDrafts();
  });

  const selectedId = $derived(page.url.searchParams.get('message'));
  const setupRequested = $derived(page.url.searchParams.get('setup') === '1');
  const draftsRequested = $derived(page.url.searchParams.get('drafts') === '1');

  // Race-safe selection load: `MailStore.select` writes into the shared
  // `mailStore.selected` singleton with no per-call id tag, so two
  // in-flight `select()` calls (rapid clicking between messages) could
  // otherwise resolve out of order. `activeId`/`activeDetail` are this
  // route's own local capture of "the detail that belongs to the
  // currently-selected id" — read synchronously off `mailStore.selected`
  // the instant THIS call's own `select()` resolves, and only committed if
  // a newer selection hasn't superseded it (`cancelled`) — a stale, slower
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
  // re-trigger this same effect — an infinite `get_mail_message` loop
  // keyed on nothing the user did (caught live on an earlier revision).
  // The effect must only re-run when `selectedId` (the URL param) changes,
  // never as a side effect of its own fetch completing.
  let activeId: string | null = $state(null);
  let activeDetail: MailMessageDetail | null = $state(null);
  let loadError = $state(false);

  $effect(() => {
    const id = selectedId;
    activeId = null;
    activeDetail = null;
    loadError = false;
    if (!id) return;

    // `select()` reads the store's selected account — none known yet (no
    // account configured, or `refreshStatus` still in flight) means there
    // is nothing to select against.
    if (!untrack(() => mailStore.selectedAccount)) {
      loadError = true;
      return;
    }

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

  // "Sync now" lives in the pane header next to the title; its in-flight
  // and error state belong to the route, and the resulting message is
  // handed to `SyncStatusLine` (the pane footer) for display.
  let syncRequesting = $state(false);
  let syncRequestError = $state<string | null>(null);
  const syncBusy = $derived(syncRequesting || mailStore.selectedStatus?.state === 'syncing');

  async function handleSyncNow(): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!account) return;

    syncRequesting = true;
    syncRequestError = null;
    const code = await mailStore.syncNow(account, workspaceStore.generation ?? 0);
    syncRequesting = false;
    if (code) syncRequestError = syncNowErrorMessage(code);
  }

  // "Clean up inbox" (mail design spec E §UI): a session on the primary ICM,
  // opted into the selected account's mail mount, opened with the pinned
  // cleanup prompt — the agent reviews views/ and declares ops files; it
  // cannot touch the mailbox directly and cannot send anything.
  let cleanupStarting = $state(false);
  let cleanupError = $state<string | null>(null);

  async function handleCleanup(): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!account) return;

    cleanupStarting = true;
    cleanupError = null;
    try {
      const mountKey = icmStore.groups[0]?.mount;
      if (!mountKey) {
        cleanupError = 'No enabled project can host the session. Enable one in the sidebar.';
        return;
      }
      const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0, {
        includeMounts: [`mail-${account}`]
      });
      if (!result.ok) {
        cleanupError = `Couldn't start the session (${result.error}).`;
        return;
      }
      const data = result.data as { id: string };
      setInitialPrompt(data.id, cleanupPrompt(account));
      void goto(`/chat?session=${data.id}`);
    } finally {
      cleanupStarting = false;
    }
  }
</script>

<AppFrame>
  {#snippet list()}
    <ListPane title="Mail">
      {#snippet action()}
        <Button type="button" variant="outline" size="sm" disabled={syncBusy} onclick={() => void handleSyncNow()}>
          Sync now
        </Button>
      {/snippet}
      {#snippet children()}
        <div class="flex flex-col gap-2 pb-2">
          <AccountSwitcher />
          <FolderList />
          {#if mailStore.selectedAccount}
            <div class="flex items-center gap-1.5">
              <Button type="button" variant="ghost" size="sm" onclick={() => void goto('/mail?drafts=1')}>
                Drafts{mailStore.drafts.length > 0 ? ` (${mailStore.drafts.length})` : ''}
              </Button>
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={cleanupStarting}
                onclick={() => void handleCleanup()}
              >
                Clean up inbox
              </Button>
            </div>
            {#if cleanupError}
              <p class="text-warn-ink text-[12px]" role="alert">{cleanupError}</p>
            {/if}
          {/if}
        </div>
        <MessageList messages={mailStore.messages} {selectedId} />
      {/snippet}
      {#snippet footer()}
        <SyncStatusLine
          status={mailStore.selectedStatus}
          requestError={syncRequestError}
          onSettings={() => void goto('/mail?setup=1')}
        />
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if setupRequested}
      <SetupPanel />
    {:else if draftsRequested}
      <DraftsPanel />
    {:else if !selectedId}
      {#if mailStore.accounts.length === 0}
        <SetupPanel />
      {:else}
        <EmptyState icon={MailIcon} title="Mail" body="Pick a message from the list to read it here." />
      {/if}
    {:else if activeId === selectedId && activeDetail}
      <MessageView message={activeDetail} />
    {:else if loadError}
      <p class="text-warn-ink text-[13px]" role="alert">This message could not be loaded.</p>
    {:else}
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {/if}
  {/snippet}
</AppFrame>
