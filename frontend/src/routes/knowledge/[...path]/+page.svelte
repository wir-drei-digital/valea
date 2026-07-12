<script lang="ts">
  import { page } from '$app/state';
  import { beforeNavigate, goto } from '$app/navigation';
  import { onDestroy } from 'svelte';
  import { AppFrame, ListPane, PageHeader, SegmentedControl } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { api, type IcmPageData } from '$lib/api/client';
  import { encodePath, flattenMountGroups, type IcmNode } from '$lib/shell/nav';
  import { Skeleton } from '$lib/components/ui/skeleton';
  import PageEditor from '$lib/components/editor/PageEditor.svelte';
  import PageMeta from '$lib/components/editor/PageMeta.svelte';
  import ConflictBanner from '$lib/components/editor/ConflictBanner.svelte';
  import { PageEditorStore } from '$lib/stores/page-editor.svelte';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';
  import { fileLeafKind, fileLeafLabel } from '$lib/components/knowledge/file-leaf';
  import ImageIcon from '@lucide/svelte/icons/image';
  import FileText from '@lucide/svelte/icons/file-text';
  import FileIcon from '@lucide/svelte/icons/file';

  let newEntryMode: 'page' | 'folder' = $state('page');
  let newEntryOpen = $state(false);

  function openNew(mode: 'page' | 'folder') {
    newEntryMode = mode;
    newEntryOpen = true;
  }

  // Route params arrive URL-encoded per segment (e.g. `Tone%20%26%20Voice`);
  // decode each segment rather than the whole param so a literal `%2F` in a
  // filename would never be mistaken for a path separator.
  const decodedPath = $derived(
    (page.params.path ?? '')
      .split('/')
      .map((segment) => decodeURIComponent(segment))
      .join('/')
  );

  function findNode(nodes: IcmNode[], path: string): IcmNode | undefined {
    for (const node of nodes) {
      if (node.path === path) return node;
      if (node.type === 'folder' && node.children) {
        const found = findNode(node.children, path);
        if (found) return found;
      }
    }
    return undefined;
  }

  // A-T15: this route only ever needs a flat search-by-path (never a
  // per-mount grouped display — that's `/knowledge`'s own concern, see
  // `buildMountsDisplay` in `components/knowledge/mount-sections.ts`), so it
  // flattens `icmStore.groups` rather than reading the deleted
  // `icmStore.nodes` back-compat getter. Safe: every node `path` is
  // workspace-relative (`mounts/<name>/…`, A-T3) and therefore unique across
  // mounts, so flattening never conflates two different mounts' same-named
  // folders/pages.
  const flatNodes = $derived(flattenMountGroups(icmStore.groups));

  const node = $derived(findNode(flatNodes, decodedPath));
  const isPage = $derived(node?.type === 'page');

  // Overline above the page title — the parent folder the page lives in
  // (the memory screen's kind line), or the section root for top-level pages.
  const parentLabel = $derived.by(() => {
    const segments = decodedPath.split('/').filter(Boolean);
    return segments.length > 1 ? segments[segments.length - 2] : 'Knowledge';
  });

  // The list pane always shows a folder's entries — the open folder itself,
  // or (on a page route) the folder CONTAINING the page, with the open page
  // highlighted like mail/chat's selected rows. Before this, page routes
  // rendered an empty pane. New entries created from the pane header land in
  // this listed folder (`path`), which for page routes is the parent — not
  // the page's own path.
  const listContext = $derived.by((): { title: string; path: string; entries: IcmNode[] } => {
    if (node?.type === 'folder') {
      return { title: node.name, path: node.path, entries: node.children ?? [] };
    }
    const segments = decodedPath.split('/').filter(Boolean);
    const parentPath = segments.slice(0, -1).join('/');
    const parent = parentPath ? findNode(flatNodes, parentPath) : undefined;
    if (parent?.type === 'folder') {
      return { title: parent.name, path: parent.path, entries: parent.children ?? [] };
    }
    return { title: 'Knowledge', path: '', entries: flatNodes };
  });

  type PageContent = IcmPageData;

  let content: PageContent | null = $state(null);
  let loadFailed = $state(false);
  let loading = $state(false);
  let loadedPath = $state<string | null>(null);

  let store: PageEditorStore | null = $state(null);
  let editorRef: PageEditor | null = $state(null);
  let viewMode: 'friendly' | 'raw' = $state('friendly');
  let rawText = $state('');
  // Snapshot taken the moment we last switched to raw (or reloaded) — the
  // disk truth as of that fetch. Used to decide, on switching back to
  // friendly, whether the editor's in-memory doc needs refreshing.
  let lastFetch: PageContent | null = null;
  // The hash of whatever ProseMirror doc is currently loaded into the
  // editor. Diverges from `store.hash` only in the window between a raw-view
  // fetch and switching back to friendly.
  let editorHash = '';
  // `~N tokens` estimate. Computed from whatever markdown string we most
  // recently fetched (load, reload, raw toggle) — NOT recomputed on every
  // keystroke/save; that's out of scope for this phase (see task-9 brief).
  let tokenEstimate = $state(0);

  async function loadPage(path: string) {
    // A previous page's store may still hold an unflushed edit — save it
    // before tearing the store down and replacing it with a fresh one for
    // the new path.
    if (store) {
      await store.flush();
    }

    loading = true;
    loadFailed = false;
    content = null;
    store = null;
    viewMode = 'friendly';
    rawText = '';
    lastFetch = null;

    const result = await api.icmPage(path);
    if (result.ok) {
      const data = result.data as PageContent;
      content = data;
      editorHash = data.hash;
      tokenEstimate = Math.round(data.content.length / 4);
      store = new PageEditorStore(api, path, { hash: data.hash });
    } else {
      loadFailed = true;
    }
    loading = false;
    loadedPath = path;
  }

  $effect(() => {
    if (isPage && decodedPath !== loadedPath) {
      void loadPage(decodedPath);
    }
  });

  /**
   * Refetches this page and adopts the fresh state into both the editor and
   * the local metadata (`content`/`tokenEstimate`) — shared by the silent
   * `needsReload` auto-reload below and the ConflictBanner's [Reload]
   * button, which do the same thing.
   */
  async function applyReload(): Promise<void> {
    if (!store) return;
    const path = decodedPath;
    const result = await api.icmPage(path);
    if (!result.ok || path !== decodedPath) return; // stale — a newer nav has since taken over

    const data = result.data as PageContent;
    content = data;
    editorHash = data.hash;
    tokenEstimate = Math.round(data.content.length / 4);
    editorRef?.setContent(data.prosemirror);
    store.resolveReload({ hash: data.hash });
  }

  // The ICM tree carries names/counts, not a per-page content hash, so
  // there's no way to tell from `icmStore.groups` alone whether THIS page
  // changed when the tree refetches on `icm_changed`. Cheapest correct
  // thing: whenever the tree reference is replaced (any icm_changed-driven
  // refetch, including this page's own save landing on disk), refetch just
  // this page's hash and hand it to the store — `externalChange` already
  // knows how to tell a genuine foreign edit apart from an echo of our own
  // save (see page-editor.svelte.ts's class doc).
  //
  // Guarded by an in-flight flag so a burst of tree refetches doesn't pile
  // up overlapping fetches — but a refetch that arrives WHILE a check is
  // in flight must not be dropped: `externalCheckPending` records that a
  // fresher check is owed, and the loop below drains it after the current
  // fetch settles, so the LAST tree event always ends in a completed check
  // (even if several land back-to-back during one in-flight request).
  let externalCheckInFlight = false;
  let externalCheckPending = false;

  async function runExternalCheckLoop() {
    externalCheckInFlight = true;
    try {
      do {
        externalCheckPending = false;
        const activeStore = store;
        const path = decodedPath;
        if (!activeStore) break;

        try {
          const result = await api.icmPage(path);
          // Stale if a newer nav (or teardown) has since taken over.
          if (activeStore !== store || path !== decodedPath) continue;

          if (result.ok) {
            const data = result.data as PageContent;
            activeStore.externalChange(data.hash);
          } else if (result.error === 'not_found') {
            // The page vanished externally (e.g. deleted/moved outside the
            // app) — nothing local to lose, so leave quietly rather than
            // showing a dead page.
            console.warn(`icm page "${path}" no longer exists; returning to /knowledge`);
            void goto('/knowledge');
            break;
          }
        } catch {
          // Network hiccup — not fatal; the next tree event retries.
        }
      } while (externalCheckPending);
    } finally {
      externalCheckInFlight = false;
    }
  }

  $effect(() => {
    void icmStore.groups; // establishes the dependency on tree refetches
    void store; // and on the open page changing (nav between knowledge pages)
    if (!store) return;

    if (externalCheckInFlight) {
      externalCheckPending = true;
      return;
    }

    void runExternalCheckLoop();
  });

  // A clean page whose disk copy changed underneath it (`needsReload`) is
  // not a conflict — nothing local would be lost — so reload it silently
  // rather than bothering the user with the banner.
  $effect(() => {
    if (store?.needsReload) {
      void applyReload();
    }
  });

  async function showRaw(): Promise<void> {
    if (!store) return;
    // Raw always shows disk truth: flush any pending edit first so the
    // fetch below observes it, then fetch fresh regardless of what the
    // editor currently holds.
    await store.flush();
    const path = decodedPath;
    const result = await api.icmPage(path);
    if (result.ok && path === decodedPath) {
      const data = result.data as PageContent;
      rawText = data.content;
      lastFetch = data;
    }
    viewMode = 'raw';
  }

  function showFriendly(): void {
    // Coming back from raw: if the flush we did on the way in saved a
    // change (or a reload/keep-mine moved the hash while we were away), the
    // editor's in-memory doc is stale relative to what raw just showed —
    // adopt the fresh snapshot taken when we switched to raw.
    if (lastFetch && lastFetch.hash !== editorHash) {
      content = lastFetch;
      editorHash = lastFetch.hash;
      tokenEstimate = Math.round(lastFetch.content.length / 4);
      editorRef?.setContent(lastFetch.prosemirror);
    }
    viewMode = 'friendly';
  }

  function toggleView(mode: 'friendly' | 'raw'): void {
    if (mode === viewMode) return;
    if (mode === 'raw') void showRaw();
    else showFriendly();
  }

  // Route-leave: flush any unsaved edit rather than losing it. `onDestroy`
  // covers navigating away from `/knowledge` entirely; `beforeNavigate`
  // additionally covers navigating between knowledge pages (where this
  // component instance is reused and `onDestroy` never fires) — redundant
  // with the flush already inside `loadPage`, but cheap and a safety net if
  // navigation ever bypasses that path.
  beforeNavigate(() => {
    if (store) void store.flush();
  });

  onDestroy(() => {
    if (store) void store.flush();
  });
</script>

<AppFrame
  onBeforeMutateActive={async () => {
    if (!store) return Promise.resolve();
    await store.flush();
    // If the store is still dirty with an error after flushing, throw so the
    // mutation aborts and the dialog can surface the failure to the user.
    if (store.state === 'dirty' && store.error) {
      throw new Error('unsaved_changes');
    }
  }}
>
  {#snippet list()}
    <ListPane title={listContext.title}>
      {#snippet action()}
        <NewEntryButton onNew={openNew} />
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#each listContext.entries as child (child.path)}
            {@const selected = child.path === decodedPath}
            {#if child.type === 'file'}
              <!-- A-T15 fix wave: non-.md file leaf — visible but
                   non-clickable (only .md pages open in the editor). -->
              <li class="text-ink-secondary flex items-center gap-2 border-l-[3px] border-transparent py-2 pr-3 pl-3 text-[13px]">
                {#if fileLeafKind(child.ext) === 'image'}
                  <ImageIcon class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                {:else if fileLeafKind(child.ext) === 'pdf'}
                  <FileText class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                {:else}
                  <FileIcon class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                {/if}
                <span class="min-w-0 flex-1 truncate">{child.name}</span>
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">{fileLeafLabel(child.ext)}</span>
              </li>
            {:else}
              <li class="group relative">
                <a
                  href={`/knowledge/${encodePath(child.path)}`}
                  class="flex items-center gap-2 border-l-[3px] py-2 pr-9 pl-3 text-[13px] transition-colors hover:bg-paper-pill"
                  class:border-act={selected}
                  class:border-transparent={!selected}
                  class:bg-paper-card={selected}
                >
                  <span
                    class={[
                      'min-w-0 flex-1 truncate',
                      selected ? 'text-ink-heading [font-weight:650]' : 'text-ink-body'
                    ]}
                  >
                    {child.name}
                  </span>
                  {#if child.type === 'folder'}
                    <span class="text-ink-meta text-[11px] tabular-nums">{child.pageCount ?? 0}</span>
                  {/if}
                </a>
                <EntryMenu
                  path={child.path}
                  name={child.name}
                  isFolder={child.type === 'folder'}
                  class="absolute top-1/2 right-0.5 -translate-y-1/2"
                />
              </li>
            {/if}
          {/each}
        </ul>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if !icmStore.loaded}
      <div class="flex flex-col gap-3" data-testid="knowledge-loading-skeleton">
        <Skeleton class="h-6 w-1/3" />
        <Skeleton class="h-4 w-2/3" />
        <Skeleton class="h-4 w-1/2" />
      </div>
    {:else if !node}
      <p class="text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
    {:else if node.type === 'folder'}
      <PageHeader title={node.name} subtitle="Pick a page from the list to read it." />
    {:else if loading}
      <p class="text-ink-body text-[13.5px]">Loading…</p>
    {:else if loadFailed || !content || !store}
      <p class="text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
    {:else}
      <article class="flex flex-col gap-4">
        <header class="flex flex-col gap-1.5">
          <div class="flex items-center justify-between gap-3">
            <p class="text-overline">{parentLabel}</p>
            <SegmentedControl
              label="View"
              value={viewMode}
              options={[
                { value: 'friendly', label: 'Friendly view' },
                { value: 'raw', label: 'Raw' }
              ]}
              onChange={(v) => toggleView(v as 'friendly' | 'raw')}
            />
          </div>
          <h1 class="font-display text-ink-heading text-[30px] leading-tight font-medium">{content.title}</h1>
          <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
            <PageMeta state={store.state} savedAt={store.savedAt} tokens={tokenEstimate} />
            <span class="text-ink-meta font-mono text-[11.5px]">{decodedPath}</span>
          </div>
        </header>

        {#if store.state === 'dirty' && store.error === 'workspace_changed'}
          <p role="alert" class="text-warn-ink text-[12px]">
            The workspace changed while you were editing, so this page can no longer be
            saved here. Copy anything you want to keep, then reopen the page.
          </p>
        {:else if store.state === 'dirty' && store.error}
          <p role="alert" class="text-warn-ink text-[12px]">
            Couldn't save this page. Your changes are still here — retrying on your next edit.
          </p>
        {/if}

        {#if store.state === 'conflict'}
          <ConflictBanner
            onReload={() => void applyReload()}
            onKeepMine={() => void store?.resolveKeepMine()}
          />
        {/if}

        <div class:hidden={viewMode !== 'friendly'}>
          <PageEditor
            bind:this={editorRef}
            content={content.prosemirror}
            onChange={() => store?.noteChange(() => editorRef!.getJSON())}
          />
        </div>
        {#if viewMode === 'raw'}
          <pre class="whitespace-pre-wrap text-[13.5px] leading-relaxed text-ink-body">{rawText}</pre>
        {/if}

        <PageMeta frontmatter={content.frontmatter} />

        <div class="bg-paper-pill rounded-xl px-4 py-3">
          <p class="text-[13px] text-ink-body">
            This folder is yours — plain files. Export or hand it over anytime.
          </p>
        </div>
      </article>
    {/if}
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} parentPath={listContext.path} bind:open={newEntryOpen} />
