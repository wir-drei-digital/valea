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
  import { cleanupPrompt, syncNowErrorMessage, targetAccount } from '$lib/components/mail/mail-shapes';
  import { mailStore, type MailMessageDetail } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import AccountSwitcher from '$lib/components/mail/AccountSwitcher.svelte';
  import DraftsPanel from '$lib/components/mail/DraftsPanel.svelte';
  import FolderList from '$lib/components/mail/FolderList.svelte';
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import SyncStatusLine from '$lib/components/mail/SyncStatusLine.svelte';
  import MessageView from '$lib/components/mail/MessageView.svelte';
  import SetupPanel from '$lib/components/mail/SetupPanel.svelte';
  import * as Dialog from '$lib/components/ui/dialog/index.js';

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
  // `?account=` qualifies `?message=` (`messageHref`): a msg id is only
  // unique within its account, so a deep link names both.
  const selectedAccountParam = $derived(page.url.searchParams.get('account'));
  const draftsRequested = $derived(page.url.searchParams.get('drafts') === '1');

  // Accounts & settings live in a MODAL over the mail view (the calendar
  // route's Sources pattern) — `?setup=1` deep-links it open (the /sources
  // hub and older links keep working); every in-app trigger just flips the
  // state.
  let showSetup = $state(page.url.searchParams.get('setup') === '1');

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
  // `mailStore.selected`. Reading it tracked inside the effect body would
  // register it as a dependency, so that later mutation would re-trigger
  // this same effect — an infinite `get_mail_message` loop keyed on nothing
  // the user did (caught live on an earlier revision).
  //
  // `selectedAccount`/`accounts` ARE tracked, though (the untracked read
  // they replace latched this effect to whatever was known on its first
  // run): a deep link arriving before `refreshStatus` resolves has no
  // account yet, and "no account YET" must not be treated as "no account" —
  // it waits, and the effect re-runs when the accounts land.
  //
  // This effect is also the ONLY thing that switches accounts (`?account=`
  // is the source of truth — `AccountSwitcher` navigates rather than writing
  // the store, or its write would race the URL and be reverted here), so the
  // account switch runs before the `!id` bail-out: switching accounts with
  // no message open is exactly that case.
  let activeId: string | null = $state(null);
  let activeDetail: MailMessageDetail | null = $state(null);
  let loadError = $state(false);

  $effect(() => {
    const id = selectedId;
    const accountsReady = mailStore.accounts.length > 0;
    const target = targetAccount(selectedAccountParam, mailStore.selectedAccount, mailStore.accounts);
    activeId = null;
    activeDetail = null;
    loadError = false;

    let cancelled = false;
    void (async () => {
      if (target && target !== untrack(() => mailStore.selectedAccount)) {
        await mailStore.selectAccount(target);
        if (cancelled) return;
      }
      if (!id) return;
      if (!target) {
        if (accountsReady) loadError = true; // accounts loaded, none selectable
        return; // otherwise wait — effect re-runs when accounts arrive
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

  // The drafts list is workspace-wide (every account's), the pane's count is
  // not — it belongs to the account being read.
  const draftsCount = $derived(mailStore.selectedDrafts.length);

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
                Drafts{draftsCount > 0 ? ` (${draftsCount})` : ''}
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
        <MessageList messages={mailStore.messages} {selectedId} account={mailStore.selectedAccount ?? ''} />
      {/snippet}
      {#snippet footer()}
        <SyncStatusLine
          status={mailStore.selectedStatus}
          requestError={syncRequestError}
          onSettings={() => (showSetup = true)}
        />
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if draftsRequested}
      <DraftsPanel />
    {:else if !selectedId}
      {#if mailStore.accounts.length === 0}
        <!-- No mailbox yet — the welcoming path into the setup modal. -->
        <div class="mx-auto w-full max-w-[560px] px-8 py-8">
          <EmptyState
            icon={MailIcon}
            title="No mailbox connected yet."
            body="Valea mirrors your inbox into plain files on this Mac. Your assistant reads them, prepares replies as drafts, and nothing is ever sent without you."
          >
            {#snippet actions()}
              <Button type="button" onclick={() => (showSetup = true)}>Connect a mailbox</Button>
            {/snippet}
          </EmptyState>
        </div>
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

<!-- Mail accounts & settings — a modal over the mail view (same pattern as
     the calendar route's Sources dialog; SetupPanel owns its own heading). -->
<Dialog.Root bind:open={showSetup}>
  <Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-xl">
    <SetupPanel />
  </Dialog.Content>
</Dialog.Root>
