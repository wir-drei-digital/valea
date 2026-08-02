<script lang="ts">
  /**
   * The file browser as ONE pane: a tab strip above the content, the file the
   * active tab names below it, and an optional, resizable ICM tree down the
   * RIGHT edge. From the outside it is a single pane, which is the whole point —
   * nothing outside this component can observe that the tree relates to the
   * content, so there is no cross-pane sync to arrange.
   *
   * TABS, NOT SPLITS. Files used to share the content area side by side, and
   * they lost the width argument on every laptop: two files wanted a 1439px
   * window, `SPLIT_MIN` had to come down from 300 to 240 to reach one at all,
   * and a pane a tool chip created could still starve a file to twenty pixels.
   * A tab costs no width, so one file gets the whole content area at any pane
   * size. True side-by-side survives as ONE explicit control — Compare, in the
   * pane header, which is the only thing here that still consults a width.
   *
   * Owns the tab -> FileView ref map that `onBeforeMutate(href)` dispatches
   * over: with two columns compared, a rename must flush the one holding that
   * file and not its sibling.
   *
   * It also owns the assistant's auto-open CLAIM (`pane.autoIndex`, an INDEX
   * into `paths`) and is where an assistant-opened file actually lands
   * (`receiveAutoFile`) — because the claim is private to this component.
   *
   * Every path list handed upward is a fresh state from `files-pane-state.ts`,
   * and every removal re-maps the claim through `shiftAuto` first — see
   * `auto-open.ts`'s header for what skipping that costs. Removals this
   * component cannot see (a delete followed through `follow-mutation.ts`) come
   * back through `onDeleted`; the ones nothing reports at all (Back, a route
   * navigation to another file or ICM) are caught by `claim` below, which
   * refuses an index that no longer holds the file it was issued for.
   */
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import FileView from '$lib/components/views/FileView.svelte';
  import IcmTree from '$lib/components/shell/IcmTree.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';
  import { icmToNav, knowledgeHref } from '$lib/shell/nav';
  import { ancestorHrefs, RevealOnce } from '$lib/shell/reveal-path';
  import {
    TREE_MAX,
    TREE_MIN,
    TREE_W,
    clampTreeWidth,
    splitsThatFit,
    treeFits
  } from '$lib/shell/pane-fit';
  import { loadFilesSplit, saveFilesSplit } from '$lib/panes/pane-split';
  import {
    TAB_CAP,
    activateTab,
    canOpenInNewTab,
    closeTab,
    compareTarget,
    openInActiveTab,
    openInNewTab,
    resolveTabs,
    type TabState
  } from '$lib/panes/files-pane-state';
  import { autoOpen, clearAuto, shiftAuto, shiftAutoAll } from '$lib/panes/auto-open';
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
  /** The whole row (content + resizer + tree), so a drag can measure from its right edge. */
  let row = $state<HTMLElement | null>(null);

  /**
   * What the tree RENDERS at: the user's stored width, squeezed by whatever
   * this pane can spare. Everything reads this — the arithmetic below, the
   * column itself, the resizer's ARIA values — so no two of them can disagree
   * about how wide the navigator is.
   */
  const treeW = $derived(clampTreeWidth(pane.treeWidth, paneWidth));

  /** The descriptor's content half, in the shape the pure rules take. */
  const tabs = $derived<TabState>({
    paths: descriptor.paths,
    active: descriptor.active,
    compare: descriptor.compare
  });

  /**
   * The tab that was showing before this one, as a PATH rather than an index —
   * the list renumbers under it, and an index that survived a close would name
   * whatever slid into the slot. It is what Compare puts beside the active tab.
   */
  let previousPath = $state<string | null>(null);
  // Seeded by the effect's own first run rather than at init, which would read
  // `descriptor` outside a closure and capture only its initial value.
  let lastActivePath: string | null = null;
  $effect(() => {
    const now = descriptor.paths[descriptor.active] ?? null;
    if (now === lastActivePath) return;
    if (lastActivePath !== null) previousPath = lastActivePath;
    lastActivePath = now;
  });

  /**
   * The tree is only rendered when the pane can AFFORD it beside the file.
   *
   * Every programmatic pane creator — an assistant tool chip, a citation, a
   * cross-ICM re-point — deliberately ignores the width gate the bar's ＋ Pane
   * enforces, because refusing to show a file the assistant just cited would be
   * a silent failure. But a 240px `shrink-0` tree inside a 260px pane makes the
   * pane ITSELF the silent failure: the file mounts into a 20px column and the
   * row has spent a slot on nothing. Dropping the navigator instead leaves the
   * whole pane to the file the pane was created to show. See `treeFits`.
   *
   * The preference is never rewritten by this — the user's `treeVisible` is
   * intact and comes back the moment the pane is wide enough — so `treeBlocked`
   * travels to the header instead, where the toggle disables itself and says
   * why rather than claiming to show a tree that is not there.
   *
   * The rule is unchanged by the move to tabs; it simply measures the other
   * side of the pane now.
   */
  const treeShown = $derived(pane.treeVisible && treeFits(paneWidth, descriptor.paths.length, treeW));
  $effect(() => {
    pane.treeBlocked = treeFits(paneWidth, descriptor.paths.length, treeW)
      ? null
      : 'Not enough width for the tree beside a file';
  });

  /**
   * The compare escape, and the ONE place a width still decides what a Files
   * pane may hold: two columns genuinely do compete for the content area, so
   * `splitsThatFit` still governs them — measured against what is RENDERED,
   * because a tree the width just took away is width the columns get to keep,
   * and a tree the user dragged wider is width they do not.
   *
   * Below the threshold compare falls back to the active tab alone WITHOUT
   * rewriting the descriptor, so widening the window brings the comparison
   * back. The header reads `compareShown`, never the raw descriptor, or its
   * pressed state would announce a second column that is not on screen.
   */
  const compareFits = $derived(splitsThatFit(paneWidth, treeShown ? treeW : 0) >= 2);
  // ORDER IS LOAD-BEARING. `compareFits` first, so `paneWidth` is read on every
  // evaluation and is therefore a dependency of this derived even while
  // compare is off. With `descriptor.compare !== null` first, a pane that
  // mounts with compare OFF short-circuits before `compareFits` is ever read,
  // and narrowing the window afterwards did not re-evaluate this: two columns
  // of 185px and 226px survived a drop to 900px — well under `SPLIT_MIN`, the
  // exact starvation tabs exist to end — while the header button reported
  // both `aria-pressed="true"` and `aria-disabled="true"`. Found in a live
  // browser; no unit test in this repo can see it.
  //
  // `pendingCompare` counts as compare being ON: two columns are on screen,
  // the right one simply has no file in it yet. The header must read pressed
  // for the same reason it must not when the width has dropped a column — it
  // describes what is rendered.
  const compareShown = $derived(compareFits && (descriptor.compare !== null || pane.pendingCompare));
  $effect(() => {
    pane.compareShown = compareShown;
    // A SECOND TAB IS NO LONGER A PRECONDITION. Compare used to refuse below
    // two tabs and say "open a second tab to compare", which asked the user to
    // do by hand the one thing the control could obviously do for them —
    // pressing it now opens the empty second column and the next file picked
    // lands in it. What is left is the one case with nothing to put in the
    // LEFT column: an empty pane.
    pane.compareBlocked = !compareFits
      ? 'Not enough width for two files side by side'
      : descriptor.paths.length === 0
        ? 'Open a file to compare'
        : null;
  });

  // Nothing to be the left column any more — the last tab closed under an
  // armed second column. Disarming here rather than in `closeAt` catches every
  // route to an empty pane, including the ones this component never sees
  // (a delete followed through `follow-mutation.ts`, Back, a hand-edited URL).
  $effect(() => {
    if (pane.pendingCompare && descriptor.paths.length === 0) pane.clearPendingTab();
  });

  const treeNav = $derived(
    icmToNav(icmStore.groups.find((g) => g.mount === descriptor.mountKey)?.tree ?? [])
  );
  /** Every open tab is marked in the tree; the active one more strongly. */
  const activePaths = $derived(descriptor.paths.map((p) => knowledgeHref(descriptor.mountKey, p)));
  // Nothing is current while a pending tab is showing: the content area holds
  // the empty state, and a tree row claiming to be on screen over it would be
  // the same lie `treeBlocked` and `compareShown` exist to prevent.
  const currentPath = $derived(
    descriptor.paths.length === 0 || pane.pendingTab
      ? null
      : knowledgeHref(descriptor.mountKey, descriptor.paths[descriptor.active])
  );

  // The tree cannot know how many tabs its host has open, so the reason travels
  // down. Width is no longer one of them: a tab takes none.
  const newTabDisabled = $derived(
    canOpenInNewTab(tabs) ? null : `${TAB_CAP} tabs are open — close one to open another`
  );

  /**
   * The assistant's claim — but only while the tab it names still holds the
   * file it was made for.
   *
   * `descriptor.paths` is rewritten by things that never reach `closeAt` or
   * `fileVanished`: this route navigating to another file or another ICM (the
   * PRIMARY Files surface outlives all of those), Back, a hand-edited URL. An
   * index that survived one of those points at whatever slid into the slot, and
   * the next assistant read would overwrite a file the user placed. Failing the
   * claim closed costs one recycle and evicts nothing.
   */
  const claim = $derived(
    pane.autoIndex !== null && descriptor.paths[pane.autoIndex] === pane.autoPath
      ? pane.autoIndex
      : null
  );

  // Reveal the ACTIVE tab's ancestors and scroll it into view. Only the active
  // one: revealing for every open tab would fight itself.
  //
  // Gated per (mount, path) rather than per path: the same relative path in a
  // DIFFERENT ICM is a different file in a different tree, and keying on the
  // path alone silently skipped both the reveal and the scroll when a pane
  // switched mounts. `RevealOnce` is the same gate the Knowledge route uses;
  // without one, the effect re-reveals on every unrelated re-run and re-opens
  // folders the user collapsed (issue #4).
  const revealGate = new RevealOnce();
  $effect(() => {
    const showing = descriptor.paths[descriptor.active];
    if (!showing) return;
    if (!revealGate.changed(`${descriptor.mountKey}\0${showing}`)) return;
    for (const href of ancestorHrefs(descriptor.mountKey, showing)) treeOpenState.open(href);
    const target = knowledgeHref(descriptor.mountKey, showing);
    queueMicrotask(() =>
      document.querySelector(`[data-tree-href="${CSS.escape(target)}"]`)?.scrollIntoView({
        block: 'nearest'
      })
    );
  });

  // Open file -> FileView ref map, keyed by href so a rename flushes the right
  // one. `flushPending` is FileView's existing exported method
  // (FileView.svelte:56), the same one the Knowledge route calls through its
  // single `fileViewRef`. Only RENDERED files are in it — a tab that is not
  // showing has no editor to flush, because it has none mounted.
  const views: Record<string, FileView | null> = {};

  async function beforeMutate(href: string): Promise<void> {
    await views[href]?.flushPending?.();
  }

  /**
   * Flush EVERY rendered file, for a caller that is about to invalidate all of
   * them at once rather than mutate one file — the workspace switch
   * (`AppFrame`'s `onBeforeMutateActive`). `beforeMutate(href)` is the
   * per-file half of the same contract.
   */
  export async function flushAll(): Promise<void> {
    await Promise.all(Object.values(views).map((view) => view?.flushPending?.()));
  }

  function apply(next: TabState): void {
    context.openPane?.({ ...descriptor, ...next });
  }

  /**
   * A tree click. The tree drives the OPEN TAB: the active tab's file is
   * replaced, so browsing costs no tabs at all. The exception is a pending
   * empty tab, which is exactly a request for the next file to get one of its
   * own.
   */
  function openFromTree(path: string): void {
    // Only an OPEN releases the claim. Both openers ACTIVATE rather than place
    // when the file is already in a tab, and releasing a claim for a click that
    // touched no file would cost the assistant its recycling for nothing —
    // which is the same reason `showTab` releases nothing. Read before the
    // rules run, because they are what would make it look like an open.
    const placed = !descriptor.paths.includes(path);
    const next = pane.pendingTab ? openInNewTab(tabs, path) : openInActiveTab(tabs, path);
    place(next, placed);
  }

  /** The row's "Open in a new tab" affordance. Same claim release for the tab it lands in. */
  function openInTab(path: string): void {
    if (newTabDisabled) return;
    const placed = !descriptor.paths.includes(path);
    place(openInNewTab(tabs, path), placed);
  }

  /**
   * What both openers do once the rules have answered: release the claim on the
   * tab the file landed in, fill an armed compare column if there is one, and
   * retire the pending tab either way.
   *
   * The claim is released against `next.active` — where the file was PLACED —
   * not against what ends up showing, which compare moves.
   */
  function place(next: TabState, placed: boolean): void {
    const shown = pane.pendingCompare ? pairWithPrevious(next) : next;
    pane.clearPendingTab();
    if (placed) pane.autoIndex = clearAuto(pane.autoIndex, next.active);
    apply(shown);
  }

  /**
   * Compare's armed second column being filled: the file just picked takes the
   * RIGHT column and the tab that was already showing keeps the LEFT one —
   * which is the arrangement the two columns promised while the right one was
   * still empty. Activating the new tab instead would swap the sides under the
   * reader.
   *
   * `descriptor.active` still names the same file: an appended tab renumbers
   * nothing, and `openInNewTab` at the cap replaces in place and never takes
   * the active tab. Picking the tab that is already showing leaves nothing to
   * compare, and `resolveTabs` drops the partner rather than pairing a file
   * with itself.
   */
  function pairWithPrevious(next: TabState): TabState {
    return resolveTabs(next.paths, descriptor.active, next.active);
  }

  /**
   * Switching tabs is NOT an open: it places no file, so it releases no claim.
   * The assistant may go on recycling the tab it made while you read another.
   */
  function showTab(index: number): void {
    pane.clearPendingTab();
    const next = activateTab(tabs, index);
    if (next !== tabs) apply(next);
  }

  /**
   * Closing a tab RENUMBERS `paths`, so the claim — an index — has to move
   * with it or it starts pointing at whatever slid into that slot, and the
   * next assistant open silently overwrites a file the USER placed.
   * `clearAuto` covers user opens only; it does not cover removals.
   */
  function closeAt(index: number): void {
    pane.autoIndex = shiftAuto(pane.autoIndex, index);
    apply(closeTab(tabs, index));
  }

  function toggleCompare(): void {
    // Matches the `aria-disabled` control: the guard covers pointer AND
    // keyboard activation, which an `aria-disabled` button still receives.
    if (pane.compareBlocked !== null) return;
    if (descriptor.compare !== null) {
      // Turning compare off closes NEITHER tab — both stay in the strip.
      apply({ ...tabs, compare: null });
      return;
    }
    // An armed-but-unfilled second column is compare being ON, so pressing
    // again turns it off — and takes the empty tab with it rather than leaving
    // a stray "New tab" chip behind as the only trace of a comparison that
    // never happened.
    if (pane.pendingCompare) {
      pane.clearPendingTab();
      return;
    }
    const target = compareTarget(tabs, previousPath === null ? null : tabs.paths.indexOf(previousPath));
    // Nothing to put beside the active tab: the second column opens EMPTY and
    // waits for a file, which is what the tree click after it is for. The one
    // pane this cannot serve — no tabs at all — never reaches here, because
    // `compareBlocked` refuses it.
    if (target === null) {
      pane.startPendingTab(true);
      return;
    }
    apply(resolveTabs(tabs.paths, tabs.active, target));
  }

  /**
   * The header's controls live in `PaneHost`'s band and never see
   * `PaneContext`, so every action of theirs that rewrites the descriptor is
   * registered here. ＋ and closing a pending tab are NOT among them: they only
   * set `pane.pendingTab`, which both halves read.
   */
  $effect(() => {
    pane.toggleCompare = toggleCompare;
    pane.showTab = showTab;
    pane.closeTab = closeAt;
    return () => {
      pane.toggleCompare = null;
      pane.showTab = null;
      pane.closeTab = null;
    };
  });

  /**
   * A tab's file was deleted underneath it. The HOST drops the subject (and
   * keeps the pane if the others survive — `PaneContext.onVanished`), but the
   * claim is ours, and the resulting renumbering is the same one `closeAt`
   * guards against.
   */
  function fileVanished(path: string): void {
    if (!context.onVanished) return;
    pane.autoIndex = shiftAuto(pane.autoIndex, descriptor.paths.indexOf(path));
    context.onVanished(path);
  }

  /**
   * A tree row's Delete succeeded. `follow-mutation.ts` rewrites the surfaces
   * showing that entry — including this pane's `paths` — straight in the URL,
   * which makes it the ONE removal that never passes through `closeAt` or
   * `fileVanished`. It renumbers the list all the same, so the claim has to
   * move with it or the next assistant open overwrites whatever slid into the
   * freed slot: exactly the eviction the rule exists to prevent.
   *
   * A folder carries its descendants, so this can take several tabs at once,
   * which is what `shiftAutoAll` is for. A RENAME needs nothing here — it maps
   * paths in place and never changes the list's length, so the claim still
   * names the same tab.
   */
  function entryDeleted(target: { path: string; isFolder: boolean }): void {
    const removed: number[] = [];
    descriptor.paths.forEach((p, i) => {
      if (p === target.path || (target.isFolder && p.startsWith(`${target.path}/`))) removed.push(i);
    });
    pane.autoIndex = shiftAutoAll(pane.autoIndex, removed);
  }

  /**
   * A file the ASSISTANT opened — a tool chip, a citation — handed here by
   * whichever surface it was clicked in. It recycles the tab auto-open created
   * and never evicts one the user placed; `auto-open.ts` holds the rule, this
   * holds the claim.
   *
   * It lives in the pane and not in the route because the claim is an index
   * into THIS pane's `paths`, which nothing above here can see. The file
   * becomes the SHOWING tab: a citation that arrives behind the tab you are
   * reading is one you never see.
   */
  export function receiveAutoFile(path: string): void {
    const next = autoOpen(descriptor.paths, claim, path, TAB_CAP);
    const at = next.paths.indexOf(path);
    // `autoOpen` DECLINES when every tab is one the user opened (rule 3): it
    // hands back the same array, no claim, and the file is nowhere in it, so
    // `indexOf` is -1. Declining has to mean NOTHING HAPPENS. Falling through
    // would hand `resolveTabs` that -1, which clamps to 0 — so a citation the
    // pane correctly refused to open would still yank the reader from tab 4 to
    // tab 0 and drop a comparison pinned there. The claim is left alone too:
    // a refusal is not a reason to release one.
    if (at === -1) return;
    pane.autoIndex = next.autoIndex;
    pane.autoPath = next.autoIndex === null ? null : next.paths[next.autoIndex];
    // Already the tab on screen — nothing to navigate for.
    if (next.paths === descriptor.paths && at === descriptor.active) return;
    // The assistant does NOT fill an armed compare column: the user armed it
    // for a file they were about to pick, and a citation arriving in the
    // meantime would take the slot they opened.
    pane.clearPendingTab();
    apply(resolveTabs(next.paths, at, descriptor.compare));
  }

  // Announce this pane as where an assistant-opened file lands, and stand down
  // when it goes. Re-runs whenever the host hands down a fresh `context`
  // object (side panes get one per render), which is a no-op re-registration.
  $effect(() => {
    context.registerFileTarget?.(receiveAutoFile);
    // A surface the assistant CREATED: its one tab is an auto-open that landed
    // before this component existed, so the claim could not be recorded at the
    // time. Without picking it up here the assistant's first read is stranded
    // in a tab it can never recycle, and its second read takes another —
    // burning two on the flow that opens a Files pane in the first place.
    // One-shot: asking consumes it.
    const created = context.takeAutoCreatedPath?.() ?? null;
    const at = created === null ? -1 : descriptor.paths.indexOf(created);
    // Gated on the VALIDATED claim, not the raw index: after a cross-ICM open
    // the stored index is stale rather than absent, and a stale claim must not
    // be what stops the new one being recorded.
    if (at !== -1 && claim === null) {
      pane.autoIndex = at;
      pane.autoPath = created;
    }
    return () => context.registerFileTarget?.(null);
  });

  /**
   * The FILES the content area renders: one, or two when compare is on. A BARE
   * pending tab empties it — the empty state takes the whole pane, which is
   * what "＋, now pick something" looks like. An ARMED one does not: the file
   * being read keeps the left column and only the right one is waiting.
   */
  const columns = $derived(
    descriptor.paths.length === 0 || (pane.pendingTab && !pane.pendingCompare)
      ? []
      : compareShown && descriptor.compare !== null
        ? [descriptor.paths[descriptor.active], descriptor.paths[descriptor.compare]]
        : [descriptor.paths[descriptor.active]]
  );

  /**
   * Compare's second column, open and waiting for a file — rendered BESIDE
   * `columns` rather than as an entry in it, so nothing downstream has to
   * carry a column that is not a file. Gated on `compareShown`, so a pane too
   * narrow for two columns falls back to the active file alone and keeps the
   * arming, exactly as a filled comparison falls back.
   */
  const pendingColumn = $derived(
    compareShown && pane.pendingCompare && descriptor.compare === null
  );

  // --- Resizing the tree ----------------------------------------------------
  //
  // Hand-rolled rather than wrapped in paneforge, unlike the compare splits
  // beside it, and the unit is why: paneforge lays out in PERCENTAGES, and a
  // navigator stored as a percentage is thin to the point of uselessness in a
  // narrow side pane and a second reading column in a wide primary — from one
  // stored number. It is also the unit `pane-fit.ts` reasons in, so a
  // percentage would have to be converted back before anything could ask
  // whether the tree still fits beside a file.
  //
  // What it keeps from `PaneResizer` is everything the user meets: the same
  // 3px hairline, the same hover, `role="separator"` with live values, and
  // arrow-key resizing for anyone not using a pointer.
  const TREE_NUDGE = 16;

  function setTreeWidth(px: number): void {
    pane.treeWidth = clampTreeWidth(px, paneWidth);
  }

  function startTreeResize(event: PointerEvent): void {
    const handle = event.currentTarget as HTMLElement;
    // Measured from the ROW's right edge, which is the tree's outer edge, so
    // the width follows the pointer exactly however the pane is scrolled or
    // positioned. Captured once at pointerdown: re-measuring mid-drag would
    // read a box the drag is itself changing.
    const edge = row?.getBoundingClientRect().right;
    if (edge === undefined) return;
    event.preventDefault();
    handle.setPointerCapture(event.pointerId);
    const drag = (move: PointerEvent): void => setTreeWidth(edge - move.clientX);
    const stop = (): void => {
      handle.removeEventListener('pointermove', drag);
      handle.removeEventListener('pointerup', stop);
      handle.removeEventListener('pointercancel', stop);
      // Written ONCE, at the end: a drag crosses hundreds of pixels and every
      // one of them would otherwise be a `localStorage` write.
      pane.commitTreeWidth();
    };
    handle.addEventListener('pointermove', drag);
    handle.addEventListener('pointerup', stop);
    handle.addEventListener('pointercancel', stop);
  }

  function onTreeResizeKey(event: KeyboardEvent): void {
    // The tree is on the RIGHT, so left grows it. Nudged from what is ON
    // SCREEN (`treeW`), not from the stored preference — a tree the pane is
    // currently squeezing would otherwise jump on the first key.
    const step = event.key === 'ArrowLeft' ? TREE_NUDGE : event.key === 'ArrowRight' ? -TREE_NUDGE : 0;
    if (step === 0) return;
    event.preventDefault();
    setTreeWidth(treeW + step);
    pane.commitTreeWidth();
  }

</script>

<div bind:this={row} bind:clientWidth={paneWidth} class="flex min-h-0 min-w-0 flex-1">
  <div class="flex min-h-0 min-w-0 flex-1 flex-col">
    {#if columns.length === 0}
      <p class="text-ink-meta m-auto px-6 text-[12.5px]">Pick a file to read it.</p>
    {:else if columns.length === 1 && !pendingColumn}
      <!-- One file, the whole content area, at any pane width. That is the
           point of the tab strip above it. -->
      <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
        <FileView
          bind:this={views[knowledgeHref(descriptor.mountKey, columns[0])]}
          mountKey={descriptor.mountKey}
          path={columns[0]}
          onVanished={() => fileVanished(columns[0])}
        />
      </div>
    {:else}
      <PaneGroup
        direction="horizontal"
        class="min-h-0 flex-1"
        onLayoutChange={(l) => {
          if (l.length === 2 && Number.isFinite(l[0])) saveFilesSplit(l[0]);
        }}
      >
        {#each columns as path, i (path)}
          {#if i > 0}
            <PaneResizer
              aria-label="Resize the compared files"
              class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
            />
          {/if}
          <Pane
            order={i + 1}
            defaultSize={i === 0 ? loadFilesSplit() : undefined}
            minSize={20}
            class="flex min-h-0 min-w-0 flex-col"
          >
            <!-- Which column is which. The strip above names both files, but
                 not which side each landed on, and that is the one thing a
                 comparison has to be unambiguous about. No ✕ here: closing a
                 file is the tab's job, and compare must not be a second way to
                 lose one. -->
            <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
              <span class="text-ink-meta min-w-0 flex-1 truncate font-mono text-[11px]">{path}</span>
            </div>
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
        {#if pendingColumn}
          <PaneResizer
            aria-label="Resize the compared files"
            class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
          />
          <!-- Compare's second column before it has a file. It is a real
               column rather than a hint over the first one: the point of
               pressing Compare with a single tab open is to SEE the space the
               next file will land in, beside the one already being read. -->
          <Pane order={2} minSize={20} class="flex min-h-0 min-w-0 flex-col">
            <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
              <span class="text-ink-meta min-w-0 flex-1 truncate text-[11px] italic">New tab</span>
            </div>
            <p class="text-ink-meta m-auto px-6 text-center text-[12.5px]">
              Pick a file to compare.
            </p>
          </Pane>
        {/if}
      </PaneGroup>
    {/if}
  </div>

  {#if treeShown}
    <!-- Resizable, in pixels — see `startTreeResize`. It sits between the
         content and the tree and looks exactly like the resizer between two
         compared files, because it is the same gesture on the same kind of
         edge.
         The suppressions are the ARIA window-splitter pattern, which is a
         FOCUSABLE `separator` with live values (the same shape paneforge's own
         `PaneResizer` renders): Svelte's rule reads `separator` as
         non-interactive and so objects to both the `tabindex` that makes it
         keyboard-reachable and the handlers that make it do anything. Removing
         either is what would break accessibility here, not keeping it. -->
    <!-- svelte-ignore a11y_no_noninteractive_tabindex, a11y_no_noninteractive_element_interactions -->
    <div
      role="separator"
      aria-orientation="vertical"
      aria-label="Resize the file tree"
      aria-valuenow={treeW}
      aria-valuemin={TREE_MIN}
      aria-valuemax={TREE_MAX}
      tabindex="0"
      onpointerdown={startTreeResize}
      onkeydown={onTreeResizeKey}
      ondblclick={() => {
        setTreeWidth(TREE_W);
        pane.commitTreeWidth();
      }}
      class="bg-paper-hairline hover:bg-paper-chip-border focus-visible:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize touch-none transition-colors outline-none"
    ></div>
  {/if}

  {#if treeShown}
    <!-- The tree sits on the RIGHT of the content, not the left: the tab strip
         belongs above the file it names, and a navigator between the strip and
         its content would cut the two apart.
         `TREE_W` is where it OPENS, not what it is: the width is the user's
         (`pane.treeWidth`), squeezed by whatever this pane can spare
         (`clampTreeWidth`). The border moved to the resizer's own hairline, so
         the edge is one line rather than two touching ones. -->
    <div style:width="{treeW}px" class="shrink-0 overflow-y-auto">
      <!-- `entryMenus` is explicit because this tree drives selection through
           `onSelect` (a click rewrites the descriptor, it does not navigate)
           and IcmTree reads that as picker mode, which suppresses the
           rename/delete menu. This is a file BROWSER, so the menus stay —
           and they are the only caller of `onBeforeMutate`. -->
      <IcmTree
        nodes={treeNav}
        {activePaths}
        {currentPath}
        entryMenus
        onBeforeMutate={beforeMutate}
        onSelect={(sel) => openFromTree(sel.path)}
        onOpenInTab={(sel) => openInTab(sel.path)}
        onDeleted={entryDeleted}
        openInTabDisabled={newTabDisabled}
      />
    </div>
  {/if}
</div>
