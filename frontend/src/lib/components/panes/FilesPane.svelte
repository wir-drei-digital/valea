<script lang="ts">
  /**
   * The file browser as ONE pane: an optional 240px ICM tree plus one or two
   * file splits. From the outside it is a single pane, which is the whole point
   * — nothing outside this component can observe that the tree relates to the
   * splits, so there is no cross-pane sync to arrange.
   *
   * Owns the split -> FileView ref map that `onBeforeMutate(href)` dispatches
   * over: with two editable splits, a rename must flush the split holding that
   * file and not its sibling.
   *
   * It also owns the assistant's auto-open CLAIM (`pane.autoIndex`, an INDEX
   * into `paths`). Every path list this component hands upward is a fresh
   * array from `files-pane-state.ts`, and every removal re-maps the claim
   * through `shiftAuto` first — see `auto-open.ts`'s header for what skipping
   * that costs.
   */
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import FileView from '$lib/components/views/FileView.svelte';
  import IcmTree from '$lib/components/shell/IcmTree.svelte';
  import X from '@lucide/svelte/icons/x';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';
  import { icmToNav, knowledgeHref } from '$lib/shell/nav';
  import { ancestorHrefs } from '$lib/shell/reveal-path';
  import { splitsThatFit } from '$lib/shell/pane-fit';
  import { loadFilesSplit, saveFilesSplit } from '$lib/panes/pane-split';
  import {
    canOpenBeside,
    closeSplit,
    openAsSecond,
    openInFirst
  } from '$lib/panes/files-pane-state';
  import { clearAuto, shiftAuto } from '$lib/panes/auto-open';
  import type { FilesPaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  // The prop is `state` (PaneHost's contract) but the local binding is not:
  // Svelte reads `$state` as a store subscription on a local called `state`,
  // so the two cannot coexist in one component. Renaming here is local only —
  // the prop name the host passes is unchanged.
  let {
    descriptor,
    context,
    state: pane
  }: { descriptor: FilesPaneDescriptor; context: PaneContext; state: FilesPaneState } = $props();

  let paneWidth = $state(0);
  // How many files may sit BESIDE each other here, from this pane's own width.
  // Stays local: the header has no control that needs it any more, and the only
  // things that consult it are the two openers below. The first file is never
  // subject to it — see `files-pane-state.ts`.
  const maxSplits = $derived(splitsThatFit(paneWidth, pane.treeVisible));

  const treeNav = $derived(
    icmToNav(icmStore.groups.find((g) => g.mount === descriptor.mountKey)?.tree ?? [])
  );
  const activePaths = $derived(descriptor.paths.map((p) => knowledgeHref(descriptor.mountKey, p)));

  // The tree cannot know how wide its host is, so the reason travels down. A
  // pane too narrow for two files would REPLACE the split it was told to open
  // beside, which is a control lying about what it does.
  const besideDisabled = $derived(
    canOpenBeside(descriptor.paths, maxSplits) ? null : 'Not enough width for a second file'
  );

  // Reveal the newest split's ancestors and scroll it into view. Only the
  // newest: scrolling for both open files would fight itself.
  let revealed: string | null = null;
  $effect(() => {
    const newest = descriptor.paths.at(-1);
    if (!newest || newest === revealed) return;
    revealed = newest;
    for (const href of ancestorHrefs(descriptor.mountKey, newest)) treeOpenState.open(href);
    const target = knowledgeHref(descriptor.mountKey, newest);
    queueMicrotask(() =>
      document.querySelector(`[data-tree-href="${CSS.escape(target)}"]`)?.scrollIntoView({
        block: 'nearest'
      })
    );
  });

  // Split -> FileView ref map, keyed by href so a rename flushes the right one.
  // `flushPending` is FileView's existing exported method (FileView.svelte:56),
  // the same one the Knowledge route calls through its single `fileViewRef`.
  const views: Record<string, FileView | null> = {};

  async function beforeMutate(href: string): Promise<void> {
    await views[href]?.flushPending?.();
  }

  /**
   * Flush EVERY open split, for a caller that is about to invalidate all of
   * them at once rather than mutate one file — the workspace switch
   * (`AppFrame`'s `onBeforeMutateActive`). `beforeMutate(href)` is the
   * per-file half of the same contract.
   */
  export async function flushAll(): Promise<void> {
    await Promise.all(Object.values(views).map((view) => view?.flushPending?.()));
  }

  function setPaths(paths: string[]): void {
    context.openPane?.({ ...descriptor, paths });
  }

  /** A tree click. Lands in split 0, and releases the assistant's claim on it. */
  function openFirst(path: string): void {
    const next = openInFirst(descriptor.paths, path, maxSplits);
    pane.autoIndex = clearAuto(pane.autoIndex, next.indexOf(path));
    setPaths(next);
  }

  /** "Open beside" — split 1, same claim release for the slot it lands in. */
  function openBeside(path: string): void {
    const next = openAsSecond(descriptor.paths, path, maxSplits);
    pane.autoIndex = clearAuto(pane.autoIndex, next.indexOf(path));
    setPaths(next);
  }

  /**
   * Closing a split RENUMBERS `paths`, so the claim — an index — has to move
   * with it or it starts pointing at whatever slid into that slot, and the
   * next assistant open silently overwrites a file the USER placed.
   * `clearAuto` covers user opens only; it does not cover removals.
   */
  function closeAt(index: number): void {
    pane.autoIndex = shiftAuto(pane.autoIndex, index);
    setPaths(closeSplit(descriptor.paths, index));
  }

  /**
   * A split's file was deleted underneath it. The HOST drops the subject (and
   * keeps the pane if the sibling survives — `PaneContext.onVanished`), but
   * the claim is ours, and the resulting renumbering is the same one
   * `closeAt` guards against.
   */
  function fileVanished(path: string): void {
    if (!context.onVanished) return;
    pane.autoIndex = shiftAuto(pane.autoIndex, descriptor.paths.indexOf(path));
    context.onVanished(path);
  }
</script>

<div bind:clientWidth={paneWidth} class="flex min-h-0 min-w-0 flex-1">
  {#if pane.treeVisible}
    <!-- Fixed 240px and deliberately not resizable: it is a navigator, not a
         second reading surface, and a draggable edge here would compete with
         the split divider a few hundred pixels to its right. -->
    <div class="border-paper-hairline w-[240px] shrink-0 overflow-y-auto border-r">
      <!-- `entryMenus` is explicit because this tree drives selection through
           `onSelect` (a click rewrites the descriptor, it does not navigate)
           and IcmTree reads that as picker mode, which suppresses the
           rename/delete menu. This is a file BROWSER, so the menus stay —
           and they are the only caller of `onBeforeMutate`. -->
      <IcmTree
        nodes={treeNav}
        {activePaths}
        entryMenus
        onBeforeMutate={beforeMutate}
        onSelect={(sel) => openFirst(sel.path)}
        onOpenBeside={(sel) => openBeside(sel.path)}
        openBesideDisabled={besideDisabled}
      />
    </div>
  {/if}

  {#if descriptor.paths.length === 0}
    <p class="text-ink-meta m-auto px-6 text-[12.5px]">Pick a file to read it.</p>
  {:else}
    <PaneGroup
      direction="horizontal"
      class="min-h-0 flex-1"
      onLayoutChange={(l) => {
        if (l.length === 2 && Number.isFinite(l[0])) saveFilesSplit(l[0]);
      }}
    >
      {#each descriptor.paths as path, i (path)}
        {#if i > 0}
          <PaneResizer
            aria-label="Resize split"
            class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
          />
        {/if}
        <Pane
          order={i + 1}
          defaultSize={i === 0 && descriptor.paths.length === 2 ? loadFilesSplit() : undefined}
          minSize={20}
          class="flex min-h-0 min-w-0 flex-col"
        >
          {#if descriptor.paths.length > 1}
            <!-- A per-split strip exists only while there are two: with one
                 file the pane header already names it, and a second row
                 saying the same thing would just eat reading height. -->
            <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
              <span class="text-ink-meta min-w-0 flex-1 truncate font-mono text-[11px]">{path}</span>
              <button
                type="button"
                title="Close this split"
                aria-label={`Close ${path}`}
                onclick={() => closeAt(i)}
                class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
              >
                <X class="size-3.5" strokeWidth={1.5} />
              </button>
            </div>
          {/if}
          <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
            <FileView
              bind:this={views[knowledgeHref(descriptor.mountKey, path)]}
              mountKey={descriptor.mountKey}
              {path}
              onVanished={() => fileVanished(path)}
            />
          </div>
        </Pane>
      {/each}
    </PaneGroup>
  {/if}
</div>
