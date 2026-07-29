<script lang="ts">
  // One open `.md` page — the whole editor experience (load, auto-save,
  // conflict/reload, raw toggle, dangling-link checks, backlinks, MRU),
  // lifted verbatim out of `routes/knowledge/[...path]/+page.svelte` in the
  // side-panes pass so it can be mounted anywhere: as that route's primary
  // view, or inside a side pane. The route keeps only what is genuinely
  // route-shaped (params, the lazy-tree ensure, the list pane, the new-entry
  // dialog); everything about the OPEN PAGE lives here.
  //
  // `path` is a prop, not a URL read: nothing in here touches `$app/state`,
  // which is what makes a second instance in a pane possible.
  import { beforeNavigate } from '$app/navigation';
  import { onDestroy } from 'svelte';
  import { SegmentedControl } from '$lib/components/shell';
  import { api, type IcmPageData } from '$lib/api/client';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recordVisit } from '$lib/stores/recent-pages';
  import { collectDocLinkPaths } from '$lib/editor/link-nav';
  import PageEditor from '$lib/components/editor/PageEditor.svelte';
  import PageMeta from '$lib/components/editor/PageMeta.svelte';
  import ConflictBanner from '$lib/components/editor/ConflictBanner.svelte';
  import { PageEditorStore } from '$lib/stores/page-editor.svelte';
  import BacklinksPanel from '$lib/components/knowledge/BacklinksPanel.svelte';

  let {
    mountKey,
    path,
    onVanished
  }: {
    mountKey: string;
    path: string;
    /**
     * The page disappeared from disk underneath us (deleted/moved outside
     * the app). The route answers this by going back to `/knowledge`; a
     * pane answers it by closing itself — which is exactly why this is a
     * callback rather than a `goto` baked in here.
     */
    onVanished?: () => void;
  } = $props();

  type PageContent = IcmPageData;

  let content: PageContent | null = $state(null);
  let loadFailed = $state(false);
  let loading = $state(false);
  // Keyed by mount AND path: a bare path is not unique across mounts (task
  // 4.2 re-key), and a pane can be re-pointed from one mount's `README.md`
  // to another's without the path ever changing.
  let loadedKey = $state<string | null>(null);

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

  const targetKey = $derived(`${mountKey}/${path}`);

  // Overline above the page title — a constant section label; the mono path
  // line right under it already names the parent folder, so repeating it
  // here read as a second, shifting title.
  const parentLabel = 'Files';

  // Dangling-link set (Task C9) — resolved page-kind link targets on THIS
  // page that don't exist on disk. Recomputed below on load/reload (the
  // `content`-watching effect) and after each save (the `store.savedAt`-
  // watching effect); passed straight to `PageEditor` so its decoration
  // plugin and click-to-create dialog can use it. `path`/`docJson` are
  // captured BEFORE the `await` and re-checked against the live `path`
  // after, same staleness-guard shape as `applyReload`/
  // `runExternalCheckLoop` below — a slow response for a page the reader
  // has since navigated away from is simply dropped.
  let dangling = $state<Set<string>>(new Set());

  async function refreshDangling(target: string, docJson: Record<string, unknown>): Promise<void> {
    const paths = collectDocLinkPaths(docJson, target);
    if (paths.length === 0) {
      if (target === path) dangling = new Set();
      return;
    }

    const result = await api.icmPathsExist(paths);
    if (!result.ok || target !== path) return;

    const data = result.data as { results: { path: string; exists: boolean }[] };
    dangling = new Set(data.results.filter((r) => !r.exists).map((r) => r.path));
  }

  async function loadPage(mount: string, target: string) {
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
    dangling = new Set();

    const result = await api.icmPage(mount, target);
    if (result.ok) {
      const data = result.data as PageContent;
      content = data;
      editorHash = data.hash;
      tokenEstimate = Math.round(data.content.length / 4);
      store = new PageEditorStore(api, mount, target, { hash: data.hash });
      // MRU (Task C9) — recorded on a genuine navigation-driven load, not
      // on the silent reloads/raw-toggle refetches elsewhere in this file.
      recordVisit(mount, target);
    } else {
      loadFailed = true;
    }
    loading = false;
    loadedKey = `${mount}/${target}`;
  }

  $effect(() => {
    if (targetKey !== loadedKey) {
      void loadPage(mountKey, path);
    }
  });

  // Dangling check, "on page load" side: fires whenever `content` is
  // (re)assigned — the initial `loadPage` fetch, `applyReload`, and
  // `showFriendly`'s adoption of a fresher raw-view snapshot all just set
  // `content`, so one effect here covers all three rather than duplicating
  // the call at each site.
  $effect(() => {
    if (!content) return;
    void refreshDangling(path, content.prosemirror);
  });

  // Dangling check, "after each save" side: `store.savedAt` changes on
  // every successful save (debounced auto-save or an explicit `flush()`),
  // so this effect is the "after each save flush" trigger from the brief.
  // Reads the LIVE in-editor doc via `editorRef.getJSON()` (what was just
  // saved), not the possibly-stale `content.prosemirror` from the initial
  // load.
  $effect(() => {
    void store?.savedAt; // establishes the dependency; the value itself isn't needed
    if (!store || !editorRef) return;
    void refreshDangling(path, editorRef.getJSON());
  });

  /**
   * Refetches this page and adopts the fresh state into both the editor and
   * the local metadata (`content`/`tokenEstimate`) — shared by the silent
   * `needsReload` auto-reload below and the ConflictBanner's [Reload]
   * button, which do the same thing.
   */
  async function applyReload(): Promise<void> {
    if (!store) return;
    const key = targetKey;
    const result = await api.icmPage(mountKey, path);
    if (!result.ok || key !== targetKey) return; // stale — a newer nav has since taken over

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
        const key = targetKey;
        const mount = mountKey;
        const target = path;
        if (!activeStore) break;

        try {
          const result = await api.icmPage(mount, target);
          // Stale if a newer nav (or teardown) has since taken over.
          if (activeStore !== store || key !== targetKey) continue;

          if (result.ok) {
            const data = result.data as PageContent;
            activeStore.externalChange(data.hash);
          } else if (result.error === 'not_found') {
            // The page vanished externally (e.g. deleted/moved outside the
            // app) — nothing local to lose, so leave quietly rather than
            // showing a dead page.
            console.warn(`icm page "${target}" no longer exists; closing the view`);
            onVanished?.();
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
    const key = targetKey;
    const result = await api.icmPage(mountKey, path);
    if (result.ok && key === targetKey) {
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

  /**
   * Flushes this page's pending edit before a mutation that would otherwise
   * lose it — the route hands this on to `AppFrame` (workspace switch,
   * `WorkspaceSwitcher`'s doc comment) AND to `IcmTree` (rename/delete on
   * the tree row matching this page's own path). Same shape
   * `RenameDialog`/`DeleteDialog` expect via `before-mutate.ts`'s
   * `withBeforeMutate`.
   */
  export async function flushPending(): Promise<void> {
    if (!store) return;
    await store.flush();
    // If the store is still dirty with an error after flushing, throw so the
    // mutation aborts and the dialog can surface the failure to the user.
    if (store.state === 'dirty' && store.error) {
      throw new Error('unsaved_changes');
    }
  }
</script>

{#if loading || (!content && !loadFailed)}
  <p class="mx-auto w-full max-w-[596px] text-ink-body text-[13.5px]">Loading…</p>
{:else if loadFailed || !content || !store}
  <p class="mx-auto w-full max-w-[596px] text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
{:else}
  <article class="flex flex-col gap-4">
    <header class="mx-auto flex w-full max-w-[596px] flex-col gap-1.5">
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
      <!-- No repeated title here — the document's own `# h1` renders in
           the editor below, in the same display-font style (tiptap.css). -->
      <div class="flex flex-wrap items-center gap-x-2.5 gap-y-1">
        <PageMeta state={store.state} savedAt={store.savedAt} tokens={tokenEstimate} />
        <span class="text-ink-meta font-mono text-[11.5px]">{path}</span>
      </div>
    </header>

    {#if store.state === 'dirty' && store.error === 'workspace_changed'}
      <p role="alert" class="mx-auto w-full max-w-[596px] text-warn-ink text-[12px]">
        The workspace changed while you were editing, so this page can no longer be
        saved here. Copy anything you want to keep, then reopen the page.
      </p>
    {:else if store.state === 'dirty' && store.error}
      <p role="alert" class="mx-auto w-full max-w-[596px] text-warn-ink text-[12px]">
        Couldn't save this page. Your changes are still here and will retry on your next edit.
      </p>
    {/if}

    {#if store.state === 'conflict'}
      <div class="mx-auto w-full max-w-[596px]">
        <ConflictBanner
          onReload={() => void applyReload()}
          onKeepMine={() => void store?.resolveKeepMine()}
        />
      </div>
    {/if}

    <div class:hidden={viewMode !== 'friendly'}>
      <PageEditor
        bind:this={editorRef}
        content={content.prosemirror}
        {mountKey}
        pagePath={path}
        {dangling}
        onChange={() => store?.noteChange(() => editorRef!.getJSON())}
      />
    </div>
    {#if viewMode === 'raw'}
      <pre class="mx-auto w-full max-w-[596px] whitespace-pre-wrap text-[13.5px] leading-relaxed text-ink-body">{rawText}</pre>
    {/if}

    <div class="mx-auto w-full max-w-[596px]">
      <PageMeta frontmatter={content.frontmatter} />
    </div>

    <div class="mx-auto w-full max-w-[596px]">
      <BacklinksPanel {mountKey} {path} />
    </div>
  </article>
{/if}
