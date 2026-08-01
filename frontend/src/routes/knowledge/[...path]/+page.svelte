<script lang="ts">
  // The knowledge FILE route. Its primary pane is the Files surface itself —
  // `FilesPane`, tree plus one or two file splits — rather than a shell list
  // column beside a single `FileView`. That is what makes the second split
  // reachable here: `?split=<path>` is the primary's second file, the tree's
  // per-row "Open beside" is what opens it, and promoting a two-split Files
  // pane onto this route carries both.
  //
  // What is left in the route is URL parsing, the lazy tree's ensure effect,
  // the create dialog, and the pane row. Everything about an OPEN FILE lives
  // in `FileView` inside the pane; everything about the tree lives in
  // `FilesPane`, including the ancestor reveal this route used to inline.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { AppFrame } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';
  import { encodePath, findIcmNode, knowledgeHref } from '$lib/shell/nav';
  import { ancestorHrefs } from '$lib/shell/reveal-path';
  import { parentPath } from './parent-path';
  import { treeFallback } from './tree-fallback';
  import FilesPane from '$lib/components/panes/FilesPane.svelte';
  import FilesPaneControls from '$lib/components/panes/FilesPaneControls.svelte';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import SessionPickerPopover from '$lib/components/knowledge/SessionPickerPopover.svelte';
  import { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';
  import { SPLIT_CAP } from '$lib/panes/files-pane-state';
  import { autoOpen } from '$lib/panes/auto-open';
  import {
    dedupeSurfaces,
    hrefWithPanes,
    parsePanes,
    type PaneDescriptor
  } from '$lib/panes/pane-route';
  import { paneWiring, type FileSelection } from '$lib/panes/pane-wiring';
  import { watchPaneMemory } from '$lib/panes/pane-memory.svelte';
  import type { PaneContext } from '$lib/panes/context';

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
  // The primary's SECOND file. `URLSearchParams` decodes for us, so this is a
  // plain ICM-relative path however the writer encoded it.
  const splitPath = $derived(page.url.searchParams.get('split'));

  // Scoped to THIS route's own mount — never flattened across every enabled
  // mount (task 4.2 re-key: a bare path is no longer unique across mounts,
  // so searching every mount's tree for it could find the wrong page).
  const mountTree = $derived(icmStore.groups.find((g) => g.mount === mountKey)?.tree ?? []);

  // Lazy tree: the store only holds levels that have been fetched, so a deep
  // link must ask for its ancestors explicitly. `ensured` records which
  // (mount, path) has a COMPLETED ensure AND what it concluded — until then,
  // a missing node means "still loading", not "doesn't exist"; and only a
  // `'missing'` conclusion may ever render as non-existence (issue #2 — a
  // failed listing concludes `'unavailable'`). Re-runs whenever the groups
  // reference changes (any icm_changed refetch) so a graft the refetch
  // dropped heals itself; in the steady state every `loadDir` inside no-ops.
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

  // Issue #2's one decision, now scoped to the TREE alone: an empty tree
  // because a fetch failed must not read as "no files". What the open file
  // itself claims is `FileView`'s business — the markdown view distinguishes
  // `not_found` from a failed load on its own, and every other format
  // reports its own load failure.
  const fallback = $derived(
    treeFallback({
      ensureStatus,
      listError: icmStore.listError,
      mountError: icmStore.mountErrors[mountKey]
    })
  );

  function retryTree(): void {
    void icmStore.refetch();
  }

  const node = $derived(findIcmNode(mountTree, decodedPath));
  // Optimistic while the lazy tree is still ensuring: a URL naming a FILE
  // (anything with an extension on its last segment) goes straight to the
  // split, which starts its own fetch rather than serializing behind the
  // ancestor-listing round trips.
  const hasExtension = $derived(/\.[^/]+$/.test(decodedPath.split('/').pop() ?? ''));
  // Folders EXPAND, they do not open — only files are valid split subjects.
  // A folder route is therefore the tree with an empty content area, which is
  // exactly `files:<mount>` with no path.
  const isFolder = $derived(!decodedPath || (node ? node.type === 'folder' : !hasExtension));

  const primaryPaths = $derived.by((): string[] => {
    if (isFolder) return [];
    // `?split=` naming the file already in the pathname is one file, not two.
    // `FilesPane` keys its `{#each}` on the path, so letting the pair through
    // is a duplicate key, which Svelte throws on during render — the whole app
    // blanks. Same guard `parsePaneParam` applies to the `|` wire form.
    return splitPath && splitPath !== decodedPath ? [decodedPath, splitPath] : [decodedPath];
  });

  // Keep the open path's ancestors expanded — a deep link should land with
  // its location visible, not hidden behind closed folders. `FilesPane` does
  // this for the file it opens; the FOLDER route has no file, so the route
  // still owns that one case. The loop this replaces is now `ancestorHrefs`.
  $effect(() => {
    if (!mountKey || !decodedPath) return;
    for (const href of ancestorHrefs(mountKey, decodedPath)) treeOpenState.open(href);
    if (isFolder) treeOpenState.open(knowledgeHref(mountKey, decodedPath));
  });

  // New entries land in the folder being shown — the open folder itself, or
  // the folder CONTAINING the open page, never the page's own path.
  const newEntryParent = $derived.by((): string => {
    if (node?.type === 'folder') return node.path;
    const parentDir = parentPath(decodedPath);
    const parent = parentDir ? findIcmNode(mountTree, parentDir) : undefined;
    return parent?.type === 'folder' ? parent.path : '';
  });

  // --- The primary Files surface ---------------------------------------------
  //
  // Chrome state is created here rather than by `PaneHost`, which only builds
  // it for SIDE panes: the primary has no host-rendered header, so the route
  // renders `FilesPaneControls` itself and owns the state both halves read.
  // Constructed directly rather than through `createFilesPaneState`, which
  // takes a descriptor it does not read: passing one here would capture
  // `mountKey`'s initial value for no purpose.
  const primaryFilesState = new FilesPaneState();

  /** Where the pane's own descriptor rewrites land: this route's URL. */
  function setPrimaryPaths(paths: string[], replace = false): void {
    const href =
      paths.length === 0
        ? // Nothing open — the mount root, which is a folder route: the tree
          // with an empty content area. Bouncing to the index instead would
          // throw away where the user was browsing.
          `/knowledge/${encodeURIComponent(mountKey)}`
        : knowledgeHref(mountKey, paths[0]) + (paths[1] ? `?split=${encodePath(paths[1])}` : '');
    void goto(hrefWithPanes(href, page.url), {
      keepFocus: true,
      noScroll: true,
      replaceState: replace
    });
  }

  /**
   * Where an assistant-opened file lands, announced by the primary `FilesPane`
   * itself. Only it can see the claim on the split auto-open created and how
   * wide it is, so the file is handed over rather than placed from here — the
   * same handover a SIDE Files pane makes through `pane-wiring.ts`.
   */
  let primaryFileTarget: ((path: string) => void) | null = null;
  /**
   * A file the assistant opened in ANOTHER ICM. That leaves this route rather
   * than rewriting the surface in place, so the landing happens across a
   * navigation and the pane cannot record the claim as it makes it — it picks
   * this up on the other side instead. Same one-shot as a pane the host
   * created, for the same reason.
   */
  let primaryAutoCreatedPath: string | null = null;

  /**
   * A file opened from inside a pane (a chat tool chip) targets the single
   * Files surface — which on this route is the PRIMARY.
   */
  function openFileInPrimary(sel: FileSelection): void {
    if (sel.mountKey !== mountKey) {
      // Another mount is a different Files surface; go there.
      primaryAutoCreatedPath = sel.path;
      void goto(hrefWithPanes(knowledgeHref(sel.mountKey, sel.path), page.url), {
        keepFocus: true,
        noScroll: true
      });
      return;
    }
    if (primaryFileTarget) {
      primaryFileTarget(sel.path);
      return;
    }
    // The pane has not announced itself yet — `auto-open.ts`'s claimless
    // floor: the first file always lands, a free split is taken, and a
    // surface whose splits are both the user's is left alone.
    const next = autoOpen(primaryPaths, null, sel.path, SPLIT_CAP);
    if (next.paths === primaryPaths) return;
    setPrimaryPaths(next.paths);
  }

  /**
   * Flushes any pending edit in EITHER split before a mutation that would
   * lose it — the workspace switch (`WorkspaceSwitcher`'s doc comment). The
   * per-file half, for rename and delete on one tree row, is `FilesPane`'s
   * own `onBeforeMutate(href)` over its split→ref map.
   */
  let filesPaneRef: FilesPane | null = $state(null);

  async function flushBeforeMutate(): Promise<void> {
    await filesPaneRef?.flushAll();
  }

  // --- Panes (`?pane=`) ------------------------------------------------------
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    mountKey ? { kind: 'files', mountKey, paths: primaryPaths } : null
  );
  const panes = $derived(dedupeSurfaces(primaryDescriptor, parsePanes(page.url.searchParams)));

  const wiring = paneWiring({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    openInPrimary: openFileInPrimary
  });

  // Reopen whatever was last beside the file browser, but only when the URL
  // names nothing itself — see `pane-memory.svelte.ts` for the three rules.
  watchPaneMemory({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor
  });

  const primaryFilesContext: PaneContext = {
    placement: 'primary',
    registerFileTarget: (open) => {
      primaryFileTarget = open;
    },
    takeAutoCreatedPath: () => {
      const path = primaryAutoCreatedPath;
      primaryAutoCreatedPath = null;
      return path;
    },
    // The pane REWRITES its own descriptor on a tree click; for the primary
    // that means navigating this route.
    openPane: (d) => {
      if (d.kind === 'files') setPrimaryPaths(d.paths);
    },
    openFile: openFileInPrimary,
    // One split's file was deleted underneath it. Per the per-subject rule,
    // the sibling stays; `replaceState` so Back never steps through it.
    // The assistant's claim on a split is re-mapped by `FilesPane` before it
    // calls this — see its `fileVanished`.
    onVanished: (subject) => setPrimaryPaths(primaryPaths.filter((p) => p !== subject), true)
  };
</script>

<AppFrame {primaryDescriptor} onBeforeMutateActive={flushBeforeMutate}>
  {#snippet main()}
    <PaneHost
      {primaryDescriptor}
      {panes}
      paneContext={wiring.paneContext}
      onClose={wiring.closePane}
      onPromote={wiring.promotePane}
    >
      {#snippet primary()}
        <div class="flex min-h-0 min-w-0 flex-1 flex-col">
          <!-- The primary's own header band. `PaneHost` renders one around
               every SIDE pane; the primary has none, so the tree toggle and
               the two route actions that used to live in the list-pane header
               sit here instead. Same vertical band as the pane headers, so
               every header rule across the row reads as one line. -->
          <div
            class="border-paper-hairline flex shrink-0 items-center gap-1 border-b px-3 pt-3 pb-2"
          >
            <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
              Files
            </span>
            <FilesPaneControls state={primaryFilesState} />
            {#if mountKey}
              <SessionPickerPopover
                {mountKey}
                onOpenSession={(id) => wiring.openBeside({ kind: 'chat', sessionId: id })}
                onNewSession={() => wiring.openBeside({ kind: 'chat-new', mountKey })}
              />
            {/if}
            <NewEntryButton onNew={openNew} />
          </div>

          {#if fallback === 'unavailable'}
            <!-- The tree is empty or stale because a fetch FAILED, not
                 because the mount has no files (issue #2) — say so and offer
                 a retry, rather than rendering silently as "no files". -->
            <p
              class="text-warn-ink border-paper-hairline shrink-0 border-b px-3 py-2 text-[12px]"
              role="alert"
              data-testid="knowledge-list-error"
            >
              Couldn't load files.
              <button type="button" class="underline underline-offset-2" onclick={retryTree}>Retry</button>
            </p>
          {/if}

          {#if primaryDescriptor?.kind === 'files'}
            <FilesPane
              bind:this={filesPaneRef}
              descriptor={primaryDescriptor}
              context={primaryFilesContext}
              state={primaryFilesState}
            />
          {/if}
        </div>
      {/snippet}
    </PaneHost>
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} {mountKey} parentPath={newEntryParent} bind:open={newEntryOpen} />
