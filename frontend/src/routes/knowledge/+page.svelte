<script lang="ts">
  // Knowledge index — workspace administration beside a tree column, and both
  // together are this route's PRIMARY pane, with `?pane=` panes to the right
  // of them. The tree column moved inside the primary when the shell's `list`
  // slot went away: it is the route's own navigator, and clicking a file
  // leaves the index for the page route (whose primary is a real `FilesPane`)
  // rather than opening one here.
  //
  // Task 9.3 relocated the sidebar's old flat/nested file tree here — the
  // column shows exactly ONE ICM's full recursive tree at a time
  // (`IcmTree`, reused from the shell — see its own doc comment),
  // selected by `?icm=<mount-key>` (Task 9.4's route scheme; see
  // `resolveIcmSelection` in `icm-route.ts`). With no `?icm=` yet, the first
  // enabled mount (config order) is selected and reflected into the URL via
  // `replaceState` (ambiguity resolution: cheap enough to always do — see
  // the effect below). A collapsed "Deactivated" group at the bottom lists
  // every disabled, non-degraded mount with a re-enable toggle; a degraded
  // mount (manifest missing/invalid, regardless of its enabled flag) shows
  // as a non-clickable warning chip instead — see `classifyMounts`.
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto, replaceState } from '$app/navigation';
  import { AppFrame, ListPane, MainColumn, PageHeader, SectionOverline, IcmTree } from '$lib/components/shell';
  import { paneWiring } from '$lib/panes/pane-wiring';
  import { paneRoom } from '$lib/shell/pane-room.svelte';
  import { watchPaneMemory } from '$lib/panes/pane-memory.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { recentPages } from '$lib/stores/recent-pages';
  import { icmToNav, knowledgeHref } from '$lib/shell/nav';
  import { resolveIcmSelection } from '$lib/shell/icm-route';
  import {
    adoptFailureBannerText,
    classifyMounts,
    degradedChipLabel
  } from '$lib/components/knowledge/mount-sections';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import SessionPickerPopover from '$lib/components/knowledge/SessionPickerPopover.svelte';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import {
    dedupeSurfaces,
    hrefWithPanes,
    paneSearchSuffix,
    parsePanes,
    type PaneDescriptor
  } from '$lib/panes/pane-route';
  import MountFromElsewhereDialog from '$lib/components/knowledge/MountFromElsewhereDialog.svelte';
  import MountsDoctorPanel from '$lib/components/knowledge/MountsDoctorPanel.svelte';
  import UnmountDialog from '$lib/components/knowledge/UnmountDialog.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';

  onMount(() => {
    // `icmStore.refetch()` is already kicked off by `AppFrame`'s own
    // `onMount` (wired once, shared across every route) — `mountsStore`,
    // by contrast, has no consumer before this page, so nothing else
    // refreshes it. Kept live afterwards by the same `mounts_changed` push
    // `wireMountsEvents` already subscribes on the shared
    // `workspace:events` join (see `mounts.svelte.ts`).
    void mountsStore.refresh();
  });

  const enabledMountKeys = $derived(
    mountsStore.mounts.filter((m) => m.enabled && !m.degraded).map((m) => m.mountKey)
  );
  const selectedMountKey = $derived(resolveIcmSelection(page.url.searchParams.get('icm'), enabledMountKeys));
  const selectedGroup = $derived(icmStore.groups.find((g) => g.mount === selectedMountKey));
  const selectedMount = $derived(mountsStore.mounts.find((m) => m.mountKey === selectedMountKey));
  const treeNav = $derived(icmToNav(selectedGroup?.tree ?? []));

  const classification = $derived(classifyMounts(mountsStore.mounts));

  // Issue #2: a failed mount list or a failed root listing for the selected
  // mount used to render as a silently empty tree — indistinguishable from a
  // mount with no files. Surfaced as an inline error + retry instead.
  const treeUnavailable = $derived(
    Boolean(icmStore.listError) || Boolean(selectedMountKey && icmStore.mountErrors[selectedMountKey])
  );

  function retryTree(): void {
    void icmStore.refetch();
  }

  // --- Panes (`?pane=`) ------------------------------------------------------
  //
  // This route's primary IS a Files surface — the tree column beside the
  // index — so it names a `files:` descriptor with no file open. That is what
  // stops a redundant second file browser opening beside it (`dedupeSurfaces`
  // collapses one surface per kind, which `panesEqual` alone could not do
  // here, since the index has no single file to compare identities with) and
  // what makes the ＋ Pane menu show Files as already open. `dedupeSurfaces`
  // also allocates, which is what keeps `PaneHost` re-deriving its row layout
  // rather than writing stale sizes back over a dragged ratio.
  //
  // The index's own content — mount selection, degraded and deactivated
  // mounts, create, unmount, the doctor — stays route-only. It is workspace
  // administration, not file browsing, and has no pane representation.
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    selectedMountKey
      ? { kind: 'files', mountKey: selectedMountKey, paths: [], active: 0, compare: null }
      : null
  );
  const panes = $derived(dedupeSurfaces(primaryDescriptor, parsePanes(page.url.searchParams)));

  const wiring = paneWiring({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    // The index shows no file, so opening one means LEAVING it for the page
    // route — panes intact.
    openInPrimary: (sel) =>
      void goto(hrefWithPanes(knowledgeHref(sel.mountKey, sel.path), page.url), {
        keepFocus: true,
        noScroll: true
      }),
    roomForPane: () => paneRoom.canAdd(panes.length)
  });

  // The session picker opens a PANE, so it answers to the same gate ＋ Pane
  // does — see `pane-room.svelte.ts` for what the two disagreeing cost.
  const pickerDisabled = $derived(
    paneRoom.canAdd(panes.length) ? null : paneRoom.reasonFor(panes.length)
  );

  // Reopen whatever was last beside the file browser, but only when the URL
  // names nothing itself — see `pane-memory.svelte.ts` for the three rules.
  // The last-opened redirect below carries the restored panes with it
  // (`hrefWithPanes`), so landing here and being bounced to a page keeps them.
  watchPaneMemory({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    // `selectedMountKey` — and therefore `primaryDescriptor` — comes from
    // `mountsStore`, which is null for the first frames of a COLD load. Acting
    // on that null writes an emptied row over a composition nobody touched.
    ready: () => mountsStore.loaded
  });

  // Suffix for the tree's links (`IcmTree`'s `linkSearch`) — opening a file
  // from the index keeps whatever is open beside it.
  const paneSearch = $derived(paneSearchSuffix(panes));

  // Task 9.4: no `?icm=` yet, but a mount resolved anyway (the "default to
  // first enabled" branch of `resolveIcmSelection`) — reflect that choice
  // into the URL so the address bar and a later reload agree on which ICM is
  // showing. `replaceState` doesn't trigger a real navigation, so this is
  // cheap enough to just always do (ambiguity resolution). Self-limiting:
  // once the param is set, `page.url.searchParams.get('icm')` is truthy on
  // the next run, so the branch never re-fires for the same selection.
  $effect(() => {
    if (!page.url.searchParams.get('icm') && selectedMountKey) {
      const url = new URL(page.url);
      url.searchParams.set('icm', selectedMountKey);
      replaceState(url, page.state);
    }
  });

  // Last-opened restore (file-browser pass): landing on the Files index
  // reopens the selected mount's most recently visited page (the
  // `recent-pages` MRU the page route records into), so "open files" puts
  // you back where you left off instead of on an empty header. Validated
  // through the lazy tree first — `ensurePathLoaded` both confirms the page
  // still exists AND pre-loads its ancestor listings, so the redirect never
  // lands on a false "doesn't exist". Attempted at most once per visit to
  // this route (deliberately NOT re-fired when the user switches mounts via
  // `?icm=` while already here — that's explicit browsing, not a landing).
  let restoreAttempted = false;

  $effect(() => {
    const mount = selectedMountKey;
    if (restoreAttempted || !mount || !icmStore.loaded) return;
    restoreAttempted = true;

    const last = recentPages().find((p) => p.mountKey === mount);
    if (!last) return;

    void icmStore.ensurePathLoaded(mount, last.path).then((result) => {
      // Only a DEFINITIVE 'found' redirects; 'missing' (deleted/renamed
      // since) and 'unavailable' (a listing failed — issue #2) both stay on
      // the index rather than gambling on a page we know nothing about.
      if (result.status !== 'found' || result.node.type !== 'page') return;
      // Still sitting on this index with the same mount selected? A user
      // who already navigated away must not be yanked back.
      if (page.url.pathname !== '/knowledge') return;
      if (resolveIcmSelection(page.url.searchParams.get('icm'), enabledMountKeys) !== mount) return;
      // Pane-preserving (side-panes pass): reloading a `/knowledge?pane=chat:…`
      // split must not drop the session on the way to the restored page.
      void goto(hrefWithPanes(knowledgeHref(mount, last.path), page.url), { replaceState: true });
    });
  });

  let newEntryMode: 'page' | 'folder' = $state('page');
  let newEntryOpen = $state(false);
  let newEntryMountKey = $state('');
  // The mount's own root is always `""` now (task 4.2 re-key — every ICM
  // path is relative to ITS OWN root, so "the mount's own root" needs no
  // string of its own any more; `create_page(mount_key, "", name)` is how
  // the backend already spells "at the mount root"). What identifies WHICH
  // mount to create into is `newEntryMountKey` above.
  let newEntryParent = $state('');

  function openNew(mountKey: string, parentPath: string, mode: 'page' | 'folder') {
    newEntryMountKey = mountKey;
    newEntryParent = parentPath;
    newEntryMode = mode;
    newEntryOpen = true;
  }

  let deactivatedOpen = $state(false);
  let reenabling: Record<string, boolean> = $state({});
  let reenableError: Record<string, string> = $state({});

  // `mountKey` (task 3.4) — `MountSummary.name` is now the ICM's DISPLAY
  // name, not its stable `icms:` config key, so every call that mutates a
  // mount must address it by `mountKey`, not `name`.
  async function reenable(mountKey: string): Promise<void> {
    reenabling = { ...reenabling, [mountKey]: true };
    reenableError = { ...reenableError, [mountKey]: '' };
    const result = await mountsStore.setEnabled(mountKey, true, workspaceStore.generation ?? 0);
    reenabling = { ...reenabling, [mountKey]: false };
    if (!result.ok) {
      reenableError = { ...reenableError, [mountKey]: result.error };
    }
  }

  // A2-T9: "Mount a folder from elsewhere…" and the mounts doctor — both
  // pinned-footer affordances (`ListPane`'s `footer` snippet), same
  // placement pattern the panel-per-feature-route precedent already sets
  // (`agent/DoctorPanel` inline in `/chat`, `mail/MailDoctorPanel` inline in
  // `/mail`'s `SetupPanel`): the mounts doctor is a mounts-shaped concern,
  // so it lives right here in mounts' own route rather than a separate
  // settings page (this app has none).
  let mountFromElsewhereOpen = $state(false);
  let doctorOpen = $state(false);

  // "Unmount" (A2-T9) — one dialog instance for every external-mount row
  // across the selected mount's header, degraded chips, and deactivated
  // list (same per-row-props pattern `DeleteDialog`/`RenameDialog` use via
  // `EntryMenu`).
  let unmountTarget = $state('');
  let unmountOpen = $state(false);

  // `mountKey` (task 3.4) — see `reenable`'s comment above.
  function openUnmount(mountKey: string): void {
    unmountTarget = mountKey;
    unmountOpen = true;
  }
</script>

<AppFrame {primaryDescriptor}>
  {#snippet main()}
    <PaneHost
      {primaryDescriptor}
      {panes}
      paneContext={wiring.paneContext}
      onClose={wiring.closePane}
      onPromote={wiring.promotePane}
    >
      {#snippet primary()}
        <!-- `MainColumn` sits INSIDE the primary snippet (never around
             `PaneHost`): the host keeps its primary mounted across pane open
             and close, and only stays that way if nothing conditional wraps
             it. The tree column sits inside it too, now that the shell has no
             `list` slot — it is this route's own navigator. -->
        <div class="flex min-h-0 min-w-0 flex-1">
          <section
            class="border-paper-hairline bg-paper-panel w-[300px] max-w-[340px] min-w-[250px] shrink-0 overflow-y-auto border-r"
          >
            <ListPane title="Files">
              {#snippet action()}
                {#if selectedMountKey}
                  {@const mountKey = selectedMountKey}
                  <div class="flex items-center gap-1">
                    <!-- Same header slot as the page route's picker — the one place
                         that exists in every knowledge route state. -->
                    <SessionPickerPopover
                      {mountKey}
                      onOpenSession={(id) => wiring.openBeside({ kind: 'chat', sessionId: id })}
                      onNewSession={() => wiring.openBeside({ kind: 'chat-new', mountKey })}
                      disabledReason={pickerDisabled}
                    />
                    <NewEntryButton onNew={(mode) => openNew(mountKey, '', mode)} />
                  </div>
                {/if}
              {/snippet}
              {#snippet children()}
                {#if selectedMountKey}
                  {@const mountKey = selectedMountKey}
                  <div class="flex items-start justify-between gap-2 px-2 pt-4 pb-1">
                    <div class="min-w-0">
                      <p class="text-overline">{selectedMount?.name ?? selectedGroup?.title ?? mountKey}</p>
                      {#if selectedMount?.description}
                        <p class="text-ink-meta mt-0.5 truncate text-[11.5px]">{selectedMount.description}</p>
                      {/if}
                      {#if selectedMount?.root}
                        <!-- A2-T5b: an external (by-reference) mount's content lives
                             outside the workspace — show WHERE, since that's not
                             otherwise implied the way an embedded mount's is. -->
                        <p class="text-ink-meta mt-0.5 truncate font-mono text-[10.5px]" title={selectedMount.root}>
                          {selectedMount.root}
                        </p>
                        <button
                          type="button"
                          onclick={() => openUnmount(mountKey)}
                          class="text-ink-meta hover:text-warn-ink mt-0.5 text-[11px] underline-offset-2 hover:underline"
                        >
                          Unmount
                        </button>
                      {/if}
                    </div>
                  </div>
                  {#if treeUnavailable}
                    <!-- Empty tree because a fetch FAILED, not because the mount has
                         no files (issue #2) — say so and offer a retry. -->
                    <p class="text-warn-ink px-3 pt-2 text-[12px]" role="alert" data-testid="knowledge-list-error">
                      Couldn't load files.
                      <button type="button" class="underline underline-offset-2" onclick={retryTree}>Retry</button>
                    </p>
                  {/if}
                  <!-- Side-panes pass: the tree carries file leaves itself now
                       (`icmToNav`), so the separate non-clickable rows that used to
                       sit below it are gone — a PDF or image row opens in
                       `FileView` like any other entry. -->
                  <div class="px-1 pb-1">
                    <IcmTree nodes={treeNav} activePaths={[page.url.pathname]} linkSearch={paneSearch} />
                  </div>
                {:else}
                  <p class="text-ink-meta px-3 py-4 text-[12.5px]">No ICM is mounted yet.</p>
                {/if}

                {#if classification.degraded.length > 0}
                  <div>
                    <SectionOverline label="Needs attention" />
                    <ul class="flex flex-col gap-1.5 px-2 pb-3">
                      {#each classification.degraded as mount (mount.mountKey)}
                        <li
                          class="bg-warn-tint text-warn-ink flex items-start gap-2 rounded-md px-2.5 py-2 text-[12px]"
                          title={degradedChipLabel(mount)}
                        >
                          <TriangleAlert class="mt-0.5 size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                          <span class="min-w-0 flex-1">
                            <span class="block truncate font-semibold">{mount.name}</span>
                            <span class="block text-[11px] opacity-90">{degradedChipLabel(mount)}</span>
                            <span class="mt-0.5 block truncate font-mono text-[10.5px] opacity-80" title={mount.root}>
                              {mount.root}
                            </span>
                            <button
                              type="button"
                              onclick={() => openUnmount(mount.mountKey)}
                              class="mt-0.5 text-[11px] underline-offset-2 hover:underline"
                            >
                              Unmount
                            </button>
                          </span>
                        </li>
                      {/each}
                    </ul>
                  </div>
                {/if}

                {#if classification.deactivated.length > 0}
                  <div>
                    <button
                      type="button"
                      onclick={() => (deactivatedOpen = !deactivatedOpen)}
                      class="text-ink-secondary hover:bg-paper-pill flex w-full items-center gap-1 rounded-md px-2 py-2 text-left text-[12.5px] transition-colors"
                    >
                      <ChevronRight
                        class={['size-3 shrink-0 transition-transform', deactivatedOpen ? 'rotate-90' : '']}
                        strokeWidth={1.5}
                      />
                      <span class="flex-1">Deactivated</span>
                      <span class="text-ink-meta text-[11px] tabular-nums">{classification.deactivated.length}</span>
                    </button>
                    {#if deactivatedOpen}
                      <ul class="flex flex-col gap-1 px-2 pb-3">
                        {#each classification.deactivated as mount (mount.mountKey)}
                          <!-- The error line lives INSIDE the <li> — a <p> as a direct
                               child of <ul> is invalid markup. -->
                          <li class="flex flex-col gap-1 py-1">
                            <div class="flex items-center justify-between gap-2">
                              <span class="min-w-0 flex-1">
                                <span class="text-ink-secondary block truncate text-[13px]">{mount.name}</span>
                                <span class="text-ink-meta block truncate font-mono text-[10.5px]" title={mount.root}>
                                  {mount.root}
                                </span>
                              </span>
                              <div class="flex shrink-0 items-center gap-1.5">
                                <Button type="button" variant="outline" size="sm" onclick={() => openUnmount(mount.mountKey)}>
                                  Unmount
                                </Button>
                                <Button
                                  type="button"
                                  variant="outline"
                                  size="sm"
                                  disabled={!!reenabling[mount.mountKey]}
                                  onclick={() => void reenable(mount.mountKey)}
                                >
                                  {reenabling[mount.mountKey] ? 'Enabling…' : 'Enable'}
                                </Button>
                              </div>
                            </div>
                            {#if reenableError[mount.mountKey]}
                              <p class="text-warn-ink text-[11px]" role="alert">{reenableError[mount.mountKey]}</p>
                            {/if}
                          </li>
                        {/each}
                      </ul>
                    {/if}
                  </div>
                {/if}
              {/snippet}

              {#snippet footer()}
                <div class="flex items-center justify-between gap-2">
                  <button
                    type="button"
                    onclick={() => (mountFromElsewhereOpen = true)}
                    class="text-ink-secondary hover:text-ink-heading text-[12px]"
                  >
                    Mount a folder from elsewhere…
                  </button>
                  <button
                    type="button"
                    onclick={() => (doctorOpen = true)}
                    class="text-ink-meta hover:text-ink-heading text-[12px]"
                  >
                    Check your mounts
                  </button>
                </div>
              {/snippet}
            </ListPane>
          </section>
          <MainColumn>
            <!-- Fix wave 1 (A2-T9): a declare-stage reference-adoption failure
                 outlives the onboarding screen (see PendingAdoptError's doc comment
                 in stores/mounts.svelte.ts) — surfaced HERE, the first mounts-shaped
                 surface a fresh workspace lands on, as a prominent dismissible
                 banner. Rendered above BOTH main-pane states (header and doctor)
                 so toggling the doctor can't hide it. -->
            {#if mountsStore.pendingAdoptError}
              <div
                role="alert"
                class="bg-warn-tint text-warn-ink mb-4 flex items-start gap-2.5 rounded-lg px-4 py-3"
              >
                <TriangleAlert class="mt-0.5 size-4 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                <p class="min-w-0 flex-1 text-[13px] leading-relaxed">
                  {adoptFailureBannerText(mountsStore.pendingAdoptError)}
                </p>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  class="shrink-0"
                  onclick={() => mountsStore.clearPendingAdoptError()}
                >
                  Dismiss
                </Button>
              </div>
            {/if}

            {#if doctorOpen}
              <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
                <button
                  type="button"
                  onclick={() => (doctorOpen = false)}
                  class="text-ink-secondary hover:text-ink-heading mb-2 flex items-center gap-1 text-[12.5px]"
                >
                  <ChevronLeft class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
                  Back to Files
                </button>
                <MountsDoctorPanel generation={workspaceStore.generation ?? 0} />
              </div>
            {:else}
              <PageHeader
                title="Files"
                subtitle="Your business memory. Every page is a plain Markdown file in your workspace."
              />
            {/if}
          </MainColumn>
        </div>
      {/snippet}
    </PaneHost>
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} mountKey={newEntryMountKey} parentPath={newEntryParent} bind:open={newEntryOpen} />
<MountFromElsewhereDialog bind:open={mountFromElsewhereOpen} />
<UnmountDialog name={unmountTarget} bind:open={unmountOpen} />
