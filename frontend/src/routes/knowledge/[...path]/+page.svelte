<script lang="ts">
  import { page } from '$app/state';
  import { beforeNavigate, goto } from '$app/navigation';
  import { onDestroy } from 'svelte';
  import { AppFrame, ListPane } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { api } from '$lib/api/client';
  import { encodePath, type IcmNode } from '$lib/shell/nav';
  import { Skeleton } from '$lib/components/ui/skeleton';
  import { Button } from '$lib/components/ui/button/index.js';
  import PageEditor from '$lib/components/editor/PageEditor.svelte';
  import PageMeta from '$lib/components/editor/PageMeta.svelte';
  import ConflictBanner from '$lib/components/editor/ConflictBanner.svelte';
  import { PageEditorStore } from '$lib/stores/page-editor.svelte';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';

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

  const node = $derived(findNode(icmStore.nodes, decodedPath));
  const isPage = $derived(node?.type === 'page');

  type PageContent = {
    path: string;
    title: string;
    uri: string;
    content: string;
    hash: string;
    prosemirror: Record<string, unknown>;
  };

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
  // there's no way to tell from `icmStore.nodes` alone whether THIS page
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
    void icmStore.nodes; // establishes the dependency on tree refetches
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

<AppFrame onBeforeMutateActive={() => store?.flush() ?? Promise.resolve()}>
  {#snippet list()}
    <ListPane>
      {#snippet header()}
        <p class="text-overline">{node?.type === 'folder' ? node.name : 'Knowledge'}</p>
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#if node?.type === 'folder'}
            {#each node.children ?? [] as child (child.path)}
              <li class="group relative">
                <a
                  href={`/knowledge/${encodePath(child.path)}`}
                  class="flex items-center gap-2 py-2 pr-9 pl-3 text-[13px] text-ink-body transition-colors hover:bg-paper-pill"
                >
                  <span class="min-w-0 flex-1 truncate">{child.name}</span>
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
            {/each}
          {/if}
        </ul>
      {/snippet}
      {#snippet footer()}
        {#if node?.type === 'folder'}
          <div class="flex gap-2">
            <Button type="button" variant="outline" size="sm" class="flex-1" onclick={() => openNew('page')}>
              New page
            </Button>
            <Button type="button" variant="outline" size="sm" class="flex-1" onclick={() => openNew('folder')}>
              New folder
            </Button>
          </div>
        {/if}
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
      <header class="flex flex-col gap-2">
        <h1 class="font-display text-[24px] text-ink-heading">{node.name}</h1>
        <p class="max-w-[520px] text-[13.5px] text-ink-body">Pick a page from the list to read it.</p>
      </header>
    {:else if loading}
      <p class="text-ink-body text-[13.5px]">Loading…</p>
    {:else if loadFailed || !content || !store}
      <p class="text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
    {:else}
      <article class="flex flex-col gap-4">
        <div class="flex items-center justify-between gap-3">
          <div class="flex items-center gap-3">
            <p class="font-mono text-ink-meta text-[12px]">icm/{decodedPath}</p>
            <div role="tablist" aria-label="View" class="bg-paper-track inline-flex items-center rounded-full p-0.5">
              <button
                type="button"
                role="tab"
                aria-selected={viewMode === 'friendly'}
                class={`rounded-full px-3 py-1 text-[12px] transition-colors ${
                  viewMode === 'friendly' ? 'bg-paper-card text-ink-heading' : 'text-ink-meta'
                }`}
                onclick={() => toggleView('friendly')}
              >
                Friendly view
              </button>
              <button
                type="button"
                role="tab"
                aria-selected={viewMode === 'raw'}
                class={`rounded-full px-3 py-1 text-[12px] transition-colors ${
                  viewMode === 'raw' ? 'bg-paper-card text-ink-heading' : 'text-ink-meta'
                }`}
                onclick={() => toggleView('raw')}
              >
                Raw
              </button>
            </div>
          </div>
          <PageMeta state={store.state} savedAt={store.savedAt} tokens={tokenEstimate} />
        </div>

        {#if store.state === 'dirty' && store.error}
          <p role="alert" class="text-warn-ink text-[12px]">
            Couldn't save this page. Your changes are still here — retrying on your next edit.
          </p>
        {/if}

        <h1 class="font-display text-[24px] text-ink-heading">{content.title}</h1>

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

        <div class="bg-paper-pill rounded-xl px-4 py-3">
          <p class="text-[13px] text-ink-body">
            This folder is yours — plain files. Export or hand it over anytime.
          </p>
        </div>
      </article>
    {/if}
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} parentPath={decodedPath} bind:open={newEntryOpen} />
