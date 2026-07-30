<script lang="ts">
  // Route responsibilities only (side-panes pass): URL params, the lazy
  // tree's ensure/expand effects, the list pane, and the new-entry dialog.
  // Everything about the OPEN FILE — load, editor, save/conflict, per-format
  // viewers — lives in `FileView` now, so a side pane can mount the same
  // thing without a route.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { AppFrame, ListPane, MainColumn, PageHeader, IcmTree } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';
  import { findIcmNode, icmToNav, knowledgeHref, type IcmNode } from '$lib/shell/nav';
  import { parentPath } from './parent-path';
  import { treeFallback } from './tree-fallback';
  import { Skeleton } from '$lib/components/ui/skeleton';
  import { Button } from '$lib/components/ui/button/index.js';
  import FileView from '$lib/components/views/FileView.svelte';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import SessionPickerPopover from '$lib/components/knowledge/SessionPickerPopover.svelte';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import {
    parsePaneParam,
    paneLinkSearch,
    hrefWithPane,
    withPaneParam,
    promoteHref,
    type PaneDescriptor
  } from '$lib/panes/pane-route';

  let newEntryMode: 'page' | 'folder' = $state('page');
  let newEntryOpen = $state(false);

  function openNew(mode: 'page' | 'folder') {
    newEntryMode = mode;
    newEntryOpen = true;
  }

  // Route params (task 4.3): `/knowledge/<mountKey>/<rel...>` — the FIRST
  // segment is the mount key, everything after it is the ICM-relative path
  // (task 4.2's re-key: node paths are relative to their own mount's root
  // now, no longer globally unique across mounts, so the mount has to ride
  // in the URL alongside the path). Each segment arrives URL-encoded;
  // decode individually rather than the whole param so a literal `%2F` in a
  // filename would never be mistaken for a path separator.
  const rawSegments = $derived((page.params.path ?? '').split('/'));
  const mountKey = $derived(rawSegments[0] ? decodeURIComponent(rawSegments[0]) : '');
  const decodedPath = $derived(rawSegments.slice(1).map((segment) => decodeURIComponent(segment)).join('/'));

  // Scoped to THIS route's own mount — never flattened across every enabled
  // mount (task 4.2 re-key: a bare path is no longer unique across mounts,
  // so searching every mount's tree for it could find the wrong page).
  const mountTree = $derived(icmStore.groups.find((g) => g.mount === mountKey)?.tree ?? []);

  // Lazy tree (file-browser performance pass): the store only holds levels
  // that have been fetched, so a deep link must ask for its ancestors
  // explicitly. `ensured` records which (mount, path) has a COMPLETED ensure
  // AND what it concluded — until then, a missing node means "still
  // loading", not "doesn't exist"; and only a `'missing'` conclusion may
  // ever render as non-existence (issue #2 — a failed listing concludes
  // `'unavailable'` instead, see `treeFallback`). Re-runs whenever the
  // groups reference changes (any icm_changed refetch) so a graft the
  // refetch dropped (see IcmStore.refetch's reconcile step) heals itself; in
  // the steady state every `loadDir` inside no-ops, so this settles
  // immediately.
  let ensured = $state<{ key: string; status: 'found' | 'missing' | 'unavailable' } | null>(null);

  $effect(() => {
    void icmStore.groups;
    const mount = mountKey;
    const path = decodedPath;
    if (!mount || !path) return;
    void icmStore.ensurePathLoaded(mount, path).then((result) => {
      if (mount === mountKey && path === decodedPath) {
        ensured = { key: `${mount}\0${path}`, status: result.status };
      }
    });
  });

  const ensureStatus = $derived(ensured?.key === `${mountKey}\0${decodedPath}` ? ensured.status : null);

  // The one decision issue #2 is about: what the main pane claims when there
  // is no node to render. `'missing'` (→ "doesn't exist anymore") only on a
  // definitive miss; every failure path lands on `'unavailable'` (→ error +
  // retry) — including a failed mount list, which previously left the
  // skeleton up forever.
  const fallback = $derived(
    treeFallback({
      ensureStatus,
      listError: icmStore.listError,
      mountError: icmStore.mountErrors[mountKey]
    })
  );

  // Retry re-runs the whole chain: `refetch` re-lists the mounts and every
  // loaded level, and its groups reassignment re-fires the ensure effect
  // above (a failed dir was left unmarked, so the ensure genuinely
  // re-fetches it).
  function retryTree(): void {
    void icmStore.refetch();
  }

  // Keep the active path's ancestors expanded in the tree — a deep link (or
  // the index route's last-opened restore) should land with its location
  // visible, not hidden behind closed folders. The opened folder itself
  // (folder routes) is expanded too.
  $effect(() => {
    if (!mountKey || !decodedPath) return;
    const segments = decodedPath.split('/');
    for (let i = 0; i < segments.length - 1; i++) {
      treeOpenState.open(knowledgeHref(mountKey, segments.slice(0, i + 1).join('/')));
    }
    if (node?.type === 'folder') {
      treeOpenState.open(knowledgeHref(mountKey, node.path));
    }
  });

  // Task 9.3: the list pane renders this mount's FULL recursive tree
  // (`IcmTree`, relocated from the old sidebar) rather than just the
  // open folder's direct children — `activePath` (below) still highlights
  // where you are within it. `?icm=` is deliberately never read on this
  // route (ambiguity resolution, Task 9.4): the mount key rides the PATH
  // here, and the path always wins over any `?icm=` a stale link might
  // carry.
  // Side-panes pass: `icmToNav` emits file leaves now, so the tree itself
  // carries every entry — the separate non-clickable file rows this pane
  // used to render below it are gone.
  const treeNav = $derived(icmToNav(mountTree));

  const node = $derived(findIcmNode(mountTree, decodedPath));
  // Optimistic while the lazy tree is still ensuring: a URL that names a
  // FILE (anything with an extension on its last segment) goes straight to
  // `FileView`, which starts its own fetch rather than serializing behind
  // the ancestor-listing round trips. A stale link that turns out missing
  // lands in the view's own "doesn't exist anymore" state, same as before.
  const hasExtension = $derived(/\.[^/]+$/.test(decodedPath.split('/').pop() ?? ''));

  // The list pane always shows a folder's entries — the open folder itself,
  // or (on a page route) the folder CONTAINING the page, with the open page
  // highlighted like mail/chat's selected rows. Before this, page routes
  // rendered an empty pane. New entries created from the pane header land in
  // this listed folder (`path`), which for page routes is the parent — not
  // the page's own path.
  const listContext = $derived.by((): { path: string; entries: IcmNode[] } => {
    if (node?.type === 'folder') {
      return { path: node.path, entries: node.children ?? [] };
    }
    const parentDir = parentPath(decodedPath);
    const parent = parentDir ? findIcmNode(mountTree, parentDir) : undefined;
    if (parent?.type === 'folder') {
      return { path: parent.path, entries: parent.children ?? [] };
    }
    return { path: '', entries: mountTree };
  });

  /**
   * Flushes the open file's pending edit before a mutation that would
   * otherwise lose it — passed to `AppFrame` (workspace switch,
   * `WorkspaceSwitcher`'s doc comment) AND to `IcmTree` below (rename/delete
   * on the tree row matching this file's own path — `IcmTree` only ever
   * forwards it to the row whose `href` equals `activePath`, so every other
   * row's rename/delete skips straight to the mutate call with nothing to
   * flush). Same shape `RenameDialog`/`DeleteDialog` expect via
   * `before-mutate.ts`'s `withBeforeMutate`. `FileView` resolves it
   * immediately for every read-only format; only the markdown editor has
   * anything to save (and it throws `unsaved_changes` when a flush fails,
   * which aborts the mutation).
   */
  let fileViewRef: FileView | null = $state(null);

  async function flushBeforeMutate(): Promise<void> {
    await fileViewRef?.flushPending();
  }

  // --- Side pane (`?pane=`) — the reverse combo ---
  //
  // A chat session opens BESIDE the file you're reading (the session picker
  // in the list-pane header), mirroring `/chat`'s file panes. Same contract
  // as there: the URL is the one source of truth, so a split is linkable and
  // survives reload; `parsePaneParam` fails closed; `PaneHost` additionally
  // drops a pane duplicating the primary. Every navigation keeps focus and
  // scroll — opening a session must not blur the editor or jump the page.
  const paneDescriptor = $derived(parsePaneParam(page.url.searchParams.get('pane')));
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    decodedPath ? { kind: 'file', mountKey, path: decodedPath } : null
  );

  // Suffix for the list-pane tree's own links (see `IcmTree`'s `linkSearch`):
  // browsing files with a chat pane open keeps the pane.
  const paneSearch = $derived(paneLinkSearch(page.url));

  function openSessionPane(id: string): void {
    void goto(withPaneParam(page.url, { kind: 'chat', sessionId: id }), {
      keepFocus: true,
      noScroll: true
    });
  }

  function openNewSessionPane(): void {
    void goto(withPaneParam(page.url, { kind: 'chat-new', mountKey }), {
      keepFocus: true,
      noScroll: true
    });
  }

  function closePane(): void {
    void goto(withPaneParam(page.url, null), { keepFocus: true, noScroll: true });
  }

  /** "Open as full view" — the pane's subject becomes a route of its own. */
  function promotePane(d: PaneDescriptor): void {
    void goto(promoteHref(d));
  }

  /**
   * A chat pane opening a file navigates the PRIMARY (the pane stays) — the
   * mirror image of `/chat`, where the same click opens a side pane. Tool
   * chips and the session header's tree both land here.
   */
  function openFileAsPrimary(sel: { mountKey: string; path: string }): void {
    void goto(hrefWithPane(knowledgeHref(sel.mountKey, sel.path), page.url), { keepFocus: true, noScroll: true });
  }

  /**
   * The `chat-new` pane created its session — re-point the pane at
   * `chat:<id>` so the remounted view fires the message that was just typed
   * (`ChatView` stashes it via `setInitialPrompt` and hands the id back).
   * `replaceState` so Back doesn't step through the dead composer state.
   */
  function paneSessionCreated(id: string): void {
    void goto(withPaneParam(page.url, { kind: 'chat', sessionId: id }), {
      replaceState: true,
      keepFocus: true,
      noScroll: true
    });
  }
</script>

<AppFrame onBeforeMutateActive={flushBeforeMutate}>
  {#snippet list()}
    <!-- Always "Files", never the open folder's name: the pane is the file
         NAVIGATOR, and a header that renamed itself per folder read as a
         second, competing title beside the open document's own. Where you
         are is what the tree's selection shows. -->
    <ListPane title="Files">
      {#snippet action()}
        <div class="flex items-center gap-1">
          <!-- The one header slot every knowledge route state has (file,
               folder, index) — see the task brief's note on why the picker
               lives here rather than in `PageHeader`. -->
          {#if mountKey}
            <SessionPickerPopover {mountKey} onOpenSession={openSessionPane} onNewSession={openNewSessionPane} />
          {/if}
          <NewEntryButton onNew={openNew} />
        </div>
      {/snippet}
      {#snippet children()}
        {#if fallback === 'unavailable'}
          <!-- The tree here is empty or stale because a fetch FAILED — without
               this line the pane silently renders as "no files" (issue #2's
               screenshot: an empty list pane beside a false "doesn't exist"). -->
          <p class="text-warn-ink px-3 pt-2 text-[12px]" role="alert" data-testid="knowledge-list-error">
            Couldn't load files.
            <button type="button" class="underline underline-offset-2" onclick={retryTree}>Retry</button>
          </p>
        {/if}
        <div class="px-1 pt-1">
          <IcmTree
            nodes={treeNav}
            activePath={page.url.pathname}
            linkSearch={paneSearch}
            onBeforeMutate={flushBeforeMutate}
          />
        </div>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    <!-- `MainColumn` sits INSIDE the primary snippet, never around
         `PaneHost`: the host keeps its primary pane mounted across pane
         open/close (see its own comment), and wrapping it in something that
         flips with pane state would hand back the teardown that structure
         exists to prevent — here that would mean losing the open editor's
         unsaved keystrokes. -->
    <PaneHost
      {primaryDescriptor}
      pane={paneDescriptor}
      paneContext={{
        placement: 'pane',
        openFile: openFileAsPrimary,
        sessionCreated: paneSessionCreated,
        onArchived: closePane
      }}
      onClose={closePane}
      onPromote={promotePane}
    >
      {#snippet primary()}
        <!-- `wide` (file-browser pass): the editor container spans the full
             main pane so TABLES can grow to it; every other section (and every
             editor text block, via tiptap.css's `.page-editor` per-block caps)
             re-caps itself to the classic 596px prose column — the same content
             width the default prose column produces (660px minus its px-8). -->
        <MainColumn wide>
          {#if node?.type === 'folder'}
            <div class="mx-auto w-full max-w-[596px]">
              <PageHeader title={node.name} subtitle="Pick a page from the list to read it." />
            </div>
          {:else if node || hasExtension}
            <!-- File routes render off `FileView`'s own fetch (kicked off
                 optimistically for any path with an extension, see
                 `hasExtension`) — never gated on the lazy tree. -->
            <!-- The file vanished under us (deleted/renamed — possibly BY the
                 session in the side pane): fall back to the index, keeping
                 whatever is open beside it. -->
            <FileView
              bind:this={fileViewRef}
              {mountKey}
              path={decodedPath}
              onVanished={() => void goto(hrefWithPane('/knowledge', page.url))}
            />
          {:else if fallback === 'unavailable'}
            <!-- A listing failed somewhere (tree walk, mount list, or this
                 mount's root) — nothing is known about this page's existence,
                 so say the LOAD failed and offer a retry (issue #2). -->
            <div
              class="mx-auto flex w-full max-w-[596px] flex-col items-start gap-3"
              data-testid="knowledge-tree-error"
            >
              <p class="text-ink-body text-[13.5px]">
                Couldn't load the file list, so this page can't be shown right now. It hasn't been
                deleted — loading it just failed.
              </p>
              <Button type="button" variant="outline" size="sm" onclick={retryTree}>Retry</Button>
            </div>
          {:else if fallback === 'loading'}
            <!-- Lazy tree still ensuring this path's ancestors — a missing node
                 is "still loading" here, NOT "doesn't exist". -->
            <div
              class="mx-auto flex w-full max-w-[596px] flex-col gap-3"
              data-testid="knowledge-loading-skeleton"
            >
              <Skeleton class="h-6 w-1/3" />
              <Skeleton class="h-4 w-2/3" />
              <Skeleton class="h-4 w-1/2" />
            </div>
          {:else}
            <!-- `fallback === 'missing'` — the ensure walk COMPLETED and every
                 listing succeeded, so this is a definitive answer, the only
                 state allowed to claim non-existence. -->
            <p class="mx-auto w-full max-w-[596px] text-ink-body text-[13.5px]">
              This page doesn't exist anymore.
            </p>
          {/if}
        </MainColumn>
      {/snippet}
    </PaneHost>
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} {mountKey} parentPath={listContext.path} bind:open={newEntryOpen} />
