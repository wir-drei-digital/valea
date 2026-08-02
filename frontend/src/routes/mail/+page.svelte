<script lang="ts">
  // Mail route (mail design spec E §UI): account switcher + folder list +
  // the selected folder's messages in a list column, read pane beside it,
  // with `?message=<msg_id>` selection qualified by `?account=` — mail
  // messages aren't part of the ICM file tree, so a query param (not a path
  // segment) is the right selection mechanism here.
  //
  // Composable views: the whole thing is this route's PRIMARY pane, and
  // `?pane=` panes sit to the right of it. The list column moved inside the
  // primary when the shell's `list` slot went away — it is the route's own
  // navigator, and it carries the account switcher, search, folder picker,
  // read filter, pagination and sync footer, none of which belong in a pane.
  // What a pane gets is `MailPane`, the read surface alone.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';
  import { AppFrame, ListPane, EmptyState, MainColumn, SegmentedControl } from '$lib/components/shell';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import { dedupeSurfaces, parsePanes, type PaneDescriptor } from '$lib/panes/pane-route';
  import { paneWiring } from '$lib/panes/pane-wiring';
  import { paneRoom } from '$lib/shell/pane-room.svelte';
  import { watchPaneMemory } from '$lib/panes/pane-memory.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import FileText from '@lucide/svelte/icons/file-text';
  import ListChecks from '@lucide/svelte/icons/list-checks';
  import MailIcon from '@lucide/svelte/icons/mail';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import SearchIcon from '@lucide/svelte/icons/search';
  import Settings from '@lucide/svelte/icons/settings';
  import X from '@lucide/svelte/icons/x';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import { api } from '$lib/api/client';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import {
    cleanupPrompt,
    filterMessagesByRead,
    syncNowErrorMessage,
    type ReadFilter
  } from '$lib/components/mail/mail-shapes';
  import { watchMailSelection } from '$lib/components/mail/mail-selection.svelte';
  import { hrefWithPanes } from '$lib/panes/pane-route';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { composeHref } from '$lib/components/mail/compose';
  import AccountSwitcher from '$lib/components/mail/AccountSwitcher.svelte';
  import ComposeView from '$lib/components/mail/ComposeView.svelte';
  import DraftsPanel from '$lib/components/mail/DraftsPanel.svelte';
  import FolderPicker from '$lib/components/mail/FolderPicker.svelte';
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
    // A debounce armed as the user leaves the route would otherwise fire a
    // search into a store nothing is rendering.
    return () => cancelSearchTimer();
  });

  const selectedId = $derived(page.url.searchParams.get('message'));
  // `?account=` qualifies `?message=` (`messageHref`): a msg id is only
  // unique within its account, so a deep link names both.
  const selectedAccountParam = $derived(page.url.searchParams.get('account'));
  const draftsRequested = $derived(page.url.searchParams.get('drafts') === '1');
  // The composer's route state, `?drafts=1`'s sibling: `new` for a fresh
  // draft, any other value names the draft file to reopen. It takes the main
  // pane ahead of both the drafts panel and an open message — writing is what
  // the user asked for last.
  const composeParam = $derived(page.url.searchParams.get('compose'));

  // Accounts & settings live in a MODAL over the mail view (the calendar
  // route's Sources pattern) — `?setup=1` deep-links it open (the /sources
  // hub and older links keep working); every in-app trigger just flips the
  // state.
  let showSetup = $state(page.url.searchParams.get('setup') === '1');

  // Race-safe selection load, shared with `MailPane` — one implementation, in
  // `mail-selection.svelte.ts`. It used to live here and was copied into the
  // pane near-verbatim; the copy is gone, because the comments in it record a
  // race that was already caught live once and two copies of that reasoning
  // drift. This route's half is only WHERE the selection comes from: the URL.
  //
  // `?account=` is the source of truth for which mailbox is open —
  // `AccountSwitcher` navigates rather than writing the store, or its write
  // would race the URL and be reverted by the effect — and the effect switches
  // accounts before it looks at the message id, so switching accounts with no
  // message open is handled by the same pass.
  const selection = watchMailSelection(() => ({
    msgId: selectedId,
    account: selectedAccountParam
  }));

  // --- Panes (`?pane=`) ------------------------------------------------------
  //
  // The URL is the ONE source of truth for what sits beside the mail reader,
  // so a composition is linkable, survives reload, and Back closes a pane.
  // The route's own primary is the mail READ surface, which is why it names a
  // `mail:` descriptor: `dedupeSurfaces` uses it to drop a Mail pane that
  // would duplicate it, and the ＋ Pane menu uses it to show Mail as already
  // open. It also ALLOCATES, which is what keeps `PaneHost` re-deriving its
  // row layout instead of writing stale sizes back over a dragged ratio.
  //
  // Compose, drafts and setup are deliberately outside this: they are
  // full-screen tasks, and the pane registry's `MailPane` is the read surface
  // only.
  const primaryAccount = $derived(selectedAccountParam ?? mailStore.selectedAccount);
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    primaryAccount ? { kind: 'mail', account: primaryAccount, msgId: selectedId } : null
  );
  const panes = $derived(dedupeSurfaces(primaryDescriptor, parsePanes(page.url.searchParams)));

  // No `openInPrimary`: this route has no Files surface of its own, so a file
  // opened from a chat pane beside the reader lands in a Files pane.
  // `primary` and `slots` are what let a message's "Start a session" refuse
  // visibly: the first tells `besideRefusal` this route's own surface counts
  // toward `dedupeSurfaces`, the second gives it the window's width.
  const wiring = paneWiring({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    slots: () => paneRoom.slots
  });

  // Reopen whatever was last beside the reader, but only when the URL names
  // nothing itself — see `pane-memory.svelte.ts` for the three rules.
  watchPaneMemory({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    // `primaryAccount` falls back to `mailStore.selectedAccount`, which is
    // null until the status fetch lands. Acting on that null writes an emptied
    // row over a composition nobody touched. Set on a FAILED fetch too, so a
    // workspace with no mail still settles rather than freezing memory.
    ready: () => mailStore.statusLoaded
  });

  // The drafts list is workspace-wide (every account's), the pane's count is
  // not — it belongs to the account being read.
  const draftsCount = $derived(mailStore.selectedDrafts.length);

  // Read/unread filter over the selected folder's list — pure client-side
  // narrowing of what's already fetched (`messageSeen`: the maildir `S`
  // flag), reset to "all" whenever the folder or account changes so a
  // filtered-empty view can't masquerade as an empty folder.
  let readFilter = $state<ReadFilter>('all');

  $effect(() => {
    void mailStore.selectedAccount;
    void mailStore.selectedFolder;
    readFilter = 'all';
  });

  const visibleMessages = $derived(filterMessagesByRead(mailStore.messages, readFilter));

  // -- search (`search_mail`) -------------------------------------------------
  //
  // The typed text lives HERE, not in the store: the store exposes plain
  // `search(query)`/`clearSearch()` so it stays drivable from a test, and
  // this route owns the timer that decides when a keystroke becomes a
  // request. Results never touch the folder list, so leaving search is a
  // render switch, not a refetch.
  const SEARCH_DEBOUNCE_MS = 250;

  let searchInput = $state('');
  let searchTimer: ReturnType<typeof setTimeout> | null = null;

  const searchTerm = $derived(searchInput.trim());
  // What's in the box is what decides which list the pane shows — not what
  // has come back yet. Typing therefore swaps the folder chrome away on the
  // first keystroke rather than a debounce later.
  const searchActive = $derived(searchTerm !== '');
  // "The hits on screen aren't for this text yet" — either the debounce is
  // still counting down or the request is still out. `searchQuery` is only
  // written when a response is committed, so the comparison covers both
  // without a second flag to keep in step (see `MailStore.searchQuery`).
  const searchBusy = $derived(searchActive && mailStore.searchQuery !== searchTerm);

  function cancelSearchTimer(): void {
    if (searchTimer === null) return;
    clearTimeout(searchTimer);
    searchTimer = null;
  }

  function onSearchInput(value: string): void {
    searchInput = value;
    cancelSearchTimer();

    // Emptying the box is not a search: it restores the folder view at once
    // (and drops any response still in flight) rather than waiting out a
    // debounce for a query the backend would answer `[]` to anyway.
    if (value.trim() === '') {
      mailStore.clearSearch();
      return;
    }

    searchTimer = setTimeout(() => {
      searchTimer = null;
      void mailStore.search(value);
    }, SEARCH_DEBOUNCE_MS);
  }

  /** Esc in the box and the clear button are the same act: back to the folder list. */
  function resetSearch(): void {
    cancelSearchTimer();
    searchInput = '';
    mailStore.clearSearch();
  }

  // A `search_mail` hit belongs to the account it was found in, so switching
  // accounts empties the box (the store drops the hits themselves —
  // `selectAccount`); leaving the text behind would label another mailbox's
  // list with a query nothing had run against it.
  $effect(() => {
    void mailStore.selectedAccount;
    resetSearch();
  });

  // "Sync now" lives in the pane header's overflow menu; its in-flight
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
  // cannot touch the mailbox directly, and it has no path to transmission:
  // sending is a human action on the control-token-gated RPC surface no
  // agent session can reach (spec G §Invariant rewrite).
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
  {#snippet main()}
    <PaneHost
      {primaryDescriptor}
      {panes}
      paneContext={wiring.paneContext}
      onClose={wiring.closePane}
      onPromote={wiring.promotePane}
    >
      {#snippet primary()}
        <!-- The list column lives INSIDE the primary now that the shell has no
             `list` slot: it is this route's own navigator, not the shell's, and
             a pane opened beside the reader sits to the right of both. -->
        <div class="flex min-h-0 min-w-0 flex-1">
          <section
            class="border-paper-hairline bg-paper-panel w-[300px] max-w-[340px] min-w-[250px] shrink-0 overflow-y-auto border-r"
          >
            <ListPane title="Mail">
              {#snippet action()}
                <div class="flex items-center gap-1">
                  {#if mailStore.selectedAccount}
                    <Button
                      type="button"
                      size="sm"
                      onclick={() =>
                        void goto(hrefWithPanes(composeHref(mailStore.selectedAccount, null), page.url))}
                    >
                      Compose
                    </Button>
                  {/if}
                  <!-- One overflow menu instead of the old scattered controls
                       (Sync-now button, settings icon, Drafts/Clean-up pill row) —
                       the header stays a single calm row. -->
                  <DropdownMenu.Root>
                    <DropdownMenu.Trigger>
                      {#snippet child({ props })}
                        <button
                          type="button"
                          {...props}
                          aria-label="More mail actions"
                          title="More mail actions"
                          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill data-[state=open]:bg-paper-pill data-[state=open]:text-ink-heading flex size-8 shrink-0 items-center justify-center rounded-md transition-colors"
                        >
                          <Ellipsis class="size-4" strokeWidth={1.5} />
                        </button>
                      {/snippet}
                    </DropdownMenu.Trigger>
                    <DropdownMenu.Content align="end" class="w-52">
                      {#if mailStore.selectedAccount}
                        <DropdownMenu.Item
                          onSelect={() => void goto(hrefWithPanes('/mail?drafts=1', page.url))}
                        >
                          <FileText class="size-3.5" strokeWidth={1.5} />
                          Drafts
                          {#if draftsCount > 0}
                            <span class="bg-paper-track text-ink-meta ms-auto rounded-full px-1.5 text-[10.5px] [font-weight:650] tabular-nums">
                              {draftsCount}
                            </span>
                          {/if}
                        </DropdownMenu.Item>
                        <DropdownMenu.Item disabled={cleanupStarting} onSelect={() => void handleCleanup()}>
                          <ListChecks class="size-3.5" strokeWidth={1.5} />
                          Clean up inbox
                        </DropdownMenu.Item>
                        <DropdownMenu.Separator />
                        <DropdownMenu.Item disabled={syncBusy} onSelect={() => void handleSyncNow()}>
                          <RefreshCw class="size-3.5" strokeWidth={1.5} />
                          {syncBusy ? 'Syncing…' : 'Sync now'}
                        </DropdownMenu.Item>
                      {/if}
                      <DropdownMenu.Item onSelect={() => (showSetup = true)}>
                        <Settings class="size-3.5" strokeWidth={1.5} />
                        Mail settings
                      </DropdownMenu.Item>
                    </DropdownMenu.Content>
                  </DropdownMenu.Root>
                </div>
              {/snippet}
              {#snippet filter()}
                <div class="flex w-full flex-col gap-2">
                  <AccountSwitcher onAddAccount={() => (showSetup = true)} />
                  {#if mailStore.selectedAccount}
                    <div class="border-paper-border bg-paper-card flex h-9 items-center gap-1.5 rounded-lg border px-2.5">
                      <SearchIcon class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                      <Input
                        value={searchInput}
                        oninput={(event) => onSearchInput((event.currentTarget as HTMLInputElement).value)}
                        onkeydown={(event) => {
                          if (event.key === 'Escape') resetSearch();
                        }}
                        placeholder="Search this mailbox…"
                        aria-label="Search mail"
                        class="h-8 border-none bg-transparent px-0 shadow-none focus-visible:ring-0"
                      />
                      {#if searchInput !== ''}
                        <button
                          type="button"
                          aria-label="Clear search"
                          title="Clear search"
                          onclick={resetSearch}
                          class="text-ink-meta hover:text-ink-heading shrink-0 rounded-md p-0.5 transition-colors"
                        >
                          <X class="size-3.5" strokeWidth={1.5} />
                        </button>
                      {/if}
                    </div>
                    <!-- Both of these narrow the FOLDER list, which isn't what's on
                         screen during a search: a hit can come from any folder, and
                         a read filter over it would silently hide matches. -->
                    {#if !searchActive}
                      <div class="flex flex-wrap items-center justify-between gap-x-2 gap-y-1.5">
                        <FolderPicker />
                        <SegmentedControl
                          label="Read filter"
                          value={readFilter}
                          options={[
                            { value: 'all', label: 'All' },
                            { value: 'unread', label: 'Unread' },
                            { value: 'read', label: 'Read' }
                          ]}
                          onChange={(v) => (readFilter = v as ReadFilter)}
                        />
                      </div>
                    {/if}
                    {#if cleanupError}
                      <p class="text-warn-ink text-[12px]" role="alert">{cleanupError}</p>
                    {/if}
                  {/if}
                </div>
              {/snippet}
              {#snippet children()}
                <!-- Search replaces what the list SHOWS, never what it holds: the
                     folder rows stay loaded underneath (`mailStore.messages`), so
                     clearing the box puts them straight back with no refetch.
                     Pagination belongs to the folder listing alone — `search_mail`
                     answers one bounded set, so there is no older page to ask for.

                     The two lists also differ in SHAPE, which is why one component
                     renders both without a mode flag: folder rows are collapsed by
                     conversation (a count badge on the multi-message ones), search
                     hits are per-message and carry a snippet instead. `MessageList`
                     renders whichever fields a row actually has. -->
                {#if searchActive}
                  <MessageList
                    messages={mailStore.searchResults}
                    {selectedId}
                    account={mailStore.selectedAccount ?? ''}
                    linkUrl={page.url}
                  />
                  {#if mailStore.searchResults.length === 0}
                    <!-- A search that FAILED and one that found nothing look
                         identical from here (no hits, no query loaded) — so the
                         failure says so rather than reporting an empty mailbox the
                         app never actually got an answer about. -->
                    <p class="text-ink-meta px-3.5 py-3 text-[12.5px]" role={mailStore.searchFailed ? 'alert' : undefined}>
                      {#if searchBusy}
                        Searching…
                      {:else if mailStore.searchFailed}
                        The search couldn't be run. Try again.
                      {:else}
                        No messages match “{searchTerm}”.
                      {/if}
                    </p>
                  {/if}
                {:else}
                  <MessageList
                    messages={visibleMessages}
                    {selectedId}
                    account={mailStore.selectedAccount ?? ''}
                    linkUrl={page.url}
                  />
                  <!-- The filtered-empty note and the "Load older" row are exclusive:
                       under a note explaining that the filter hid everything, a "Load
                       older" button reads as the way to get those messages back, which
                       it is not (it fetches an older page, which the same filter then
                       hides too). The store's own guards make the row a no-op when
                       there's nothing behind the oldest loaded message. -->
                  {#if visibleMessages.length === 0 && mailStore.messages.length > 0}
                    <p class="text-ink-meta px-3.5 py-3 text-[12.5px]">
                      No {readFilter} messages in this folder.
                    </p>
                  {:else if mailStore.lastPageFull}
                    <div class="flex justify-center px-3.5 py-2">
                      <Button
                        type="button"
                        variant="ghost"
                        size="sm"
                        disabled={mailStore.loadingOlder}
                        onclick={() => void mailStore.loadOlder()}
                      >
                        {mailStore.loadingOlder ? 'Loading…' : 'Load older'}
                      </Button>
                    </div>
                  {/if}
                {/if}
              {/snippet}
              {#snippet footer()}
                <SyncStatusLine status={mailStore.selectedStatus} requestError={syncRequestError} />
              {/snippet}
            </ListPane>
          </section>
          <MainColumn>
            {#if composeParam}
              {#if mailStore.selectedAccount}
                <ComposeView
                  account={mailStore.selectedAccount}
                  draftName={composeParam === 'new' ? null : composeParam}
                />
              {:else if mailStore.accounts.length === 0}
                <EmptyState
                  icon={MailIcon}
                  title="No mailbox connected yet."
                  body="Connect a mailbox before writing mail — Valea sends only from an account you've set up."
                >
                  {#snippet actions()}
                    <Button type="button" onclick={() => (showSetup = true)}>Connect a mailbox</Button>
                  {/snippet}
                </EmptyState>
              {:else}
                <p class="text-ink-meta text-[13px]">Loading…</p>
              {/if}
            {:else if draftsRequested}
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
            {:else if selection.activeId === selectedId && selection.detail}
              <MessageView
                message={selection.detail}
                onStartSessionBeside={(d) => wiring.openBeside(d)}
                besideRefusal={(kind) => wiring.besideRefusal(kind)}
              />
            {:else if selection.failed}
              <p class="text-warn-ink text-[13px]" role="alert">This message could not be loaded.</p>
            {:else}
              <p class="text-ink-meta text-[13px]">Loading…</p>
            {/if}
          </MainColumn>
        </div>
      {/snippet}
    </PaneHost>
  {/snippet}
</AppFrame>

<!-- Mail accounts & settings — a modal over the mail view (same pattern as
     the calendar route's Sources dialog; SetupPanel owns its own heading). -->
<Dialog.Root bind:open={showSetup}>
  <Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-2xl">
    <SetupPanel />
  </Dialog.Content>
</Dialog.Root>
