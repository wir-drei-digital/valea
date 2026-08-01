<script lang="ts">
  // Renders the route's primary view plus a row of side panes (composable
  // views; deliberately not a tiling manager). Each pane slot is
  // registry-driven; chrome = title, the kind's own controls, promote ("open
  // as full view"), close.
  //
  // The host owns NO pane CONTENT state: which panes are open is the route's
  // repeated `?pane=` param (`pane-route.ts`), and every button here just
  // calls back up. What it does own is per-pane CHROME state — see
  // `paneStates` below — and the row's split layout (`pane-split.ts`).
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import { onDestroy, type Snippet } from 'svelte';
  import { paneIdentity, paneTitle, type PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import { paneEntries, type PaneState } from '$lib/panes/registry';
  import { paneRowLayout, savePaneLayout } from '$lib/panes/pane-split';
  import X from '@lucide/svelte/icons/x';
  import Maximize2 from '@lucide/svelte/icons/maximize-2';

  let {
    primary,
    // Accepted but unused: dedup against the primary happens in the ROUTE
    // (`dedupeSurfaces`), not here. Kept in the contract because every host
    // already computes it and a future rule may need it — the host renders
    // exactly what it is given so that what is on screen always matches the URL.
    primaryDescriptor = null,
    panes = [],
    paneContext,
    onClose,
    onPromote
  }: {
    primary: Snippet;
    primaryDescriptor?: PaneDescriptor | null;
    panes?: PaneDescriptor[];
    paneContext: (d: PaneDescriptor, index: number) => PaneContext;
    onClose: (index: number) => void;
    onPromote: (d: PaneDescriptor) => void;
  } = $props();

  const count = $derived(panes.length + 1);
  // Deliberately derived from `panes`, NOT from `count`: a count-only derived
  // memoizes at the pre-drag layout and paneforge then writes it back over the
  // ratio the user just dragged. `paneRowLayout`'s doc comment has the full
  // chain. It also owns the "never dragged" default, since `loadPaneLayout`
  // returns null rather than inventing one.
  const layout = $derived(paneRowLayout(panes));

  /**
   * The row, each pane paired with the key that both the `{#each}` and the
   * state cache below are keyed on. ONE list so the two can never disagree
   * about what "the same pane" means.
   *
   * The key is `paneIdentity` — the pane's SUBJECT, never its contents. It was
   * `serializePaneParam`, the full wire form, which put a Files pane's open
   * files into its own identity: clicking a file in a pane changed the string,
   * so Svelte destroyed and remounted the entire pane to show a different file
   * in it, taking the tree's scroll position, the sibling split's loaded
   * document and the per-pane state below with it. Position is deliberately
   * NOT part of the key either: closing the pane on the left must not rebuild
   * the one on the right.
   *
   * The uniquifying suffix is a guard, not a feature. Duplicate keys are
   * forbidden today — every host runs `dedupeSurfaces`, which allows one pane
   * per kind — but a duplicate `{#each}` key THROWS during render and blanks
   * the whole app (nav, bar and all), which is far too sharp an edge to leave
   * resting on an invariant enforced in another file.
   */
  const keyed = $derived.by(() => {
    const seen = new Set<string>();
    return panes.map((pane) => {
      let key = paneIdentity(pane);
      while (seen.has(key)) key += '~';
      seen.add(key);
      return { pane, key };
    });
  });

  // Per-pane chrome state (a Files tree toggle, a Chat sessions toggle) and
  // the assistant's auto-open claim are created HERE because the header
  // renders before the body mounts: a pane cannot hand stateful chrome upward
  // to its already-rendering parent. The same object goes to the header's
  // `controls` and to the body's `view`, so neither parents the other.
  //
  // Cached under the SAME key the `{#each}` is keyed on. Hosts re-derive
  // descriptors from `page.url` on every navigation, so a fresh object
  // identity means nothing; only a genuine identity change (another session,
  // another ICM, the `chat-new` -> `chat:<id>` rewrite) builds fresh state.
  // A pane that leaves the row is released.
  let cache = new Map<string, PaneState | undefined>();

  function disposeState(state: PaneState | undefined): void {
    // One documented cast: no state owns anything to release today, so the
    // union declares no `dispose`. The hook exists so the first one that does
    // is released by the host that created it, rather than by nobody.
    (state as { dispose?: () => void } | undefined)?.dispose?.();
  }

  const paneStates = $derived.by(() => {
    const next = new Map<string, PaneState | undefined>();
    for (const { pane, key } of keyed) {
      next.set(key, cache.has(key) ? cache.get(key) : paneEntries[pane.kind].createState?.(pane));
    }
    for (const [key, state] of cache) {
      if (!next.has(key)) disposeState(state);
    }
    cache = next;
    return next;
  });

  // Keeps that reconciliation running when the row EMPTIES: a lazy derived
  // that nothing renders would otherwise leave the last closed pane's state
  // held until the host itself was destroyed.
  $effect(() => void paneStates);

  onDestroy(() => {
    for (const state of cache.values()) disposeState(state);
    cache.clear();
  });

  // Fired on every drag AND on every mount/unmount, so the length guard is
  // what keeps a two-pane arrangement from overwriting the three-pane one
  // mid-transition. The finite guard keeps `savePaneLayout` from ever
  // persisting the string "NaN".
  function onLayoutChange(next: number[]): void {
    if (next.length === count && next.every(Number.isFinite)) savePaneLayout(count, next);
  }
</script>

<!--
  The PaneGroup and the primary Pane are UNCONDITIONAL, and only the resizers +
  side panes are conditional. This is load-bearing, not stylistic: Svelte's
  `{#if}`/`{:else}` branches are separate effect trees, so hosting the primary
  in one branch and bare in the other would destroy and rebuild it on every
  pane open and close — tearing down the open session's channel (join/leave
  churn `ChatView`'s own header comment forbids), dropping the composer's
  unsent draft, and replaying the transcript from the top. Opening a file from
  a tool chip mid-draft has to be free. paneforge supports panes coming and
  going (`order` pins the primary first regardless of mount timing), and a lone
  primary lays out at 100% — `defaultPaneLayout(1)`.

  Nothing here is ever hidden-but-mounted: a pane is mounted or it is gone, so
  requested, mounted and visible panes are always one set.
-->
<PaneGroup direction="horizontal" class="min-h-0 flex-1" {onLayoutChange}>
  <Pane order={1} defaultSize={layout[0]} minSize={20} class="flex min-h-0 min-w-0 flex-col">
    {@render primary()}
  </Pane>
  {#each keyed as { pane, key }, i (key)}
    {@const entry = paneEntries[pane.kind]}
    {@const state = paneStates.get(key)}
    <PaneResizer
      aria-label="Resize pane"
      class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
    />
    <!-- `order` is i + 2, not i + 1: the primary holds 1 unconditionally, so
         the row keeps its left-to-right URL order however panes mount. -->
    <Pane
      order={i + 2}
      defaultSize={layout[i + 1]}
      minSize={18}
      class="bg-paper-panel flex min-h-0 min-w-0 flex-col"
    >
      <!-- Same vertical band as the chat header (pt-3 + 24px content row +
           pb-2), so every header rule across the row reads as one continuous
           line. size-8/-my-1.5 buttons keep >=32px hit targets without
           growing the band. -->
      <div class="border-paper-hairline flex shrink-0 items-center gap-1 border-b px-3 pt-3 pb-2">
        <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
          {paneTitle(pane)}
        </span>
        {#if entry.controls && state}
          {@const Controls = entry.controls}
          <Controls {state} />
        {/if}
        <button
          type="button"
          title="Open as full view"
          aria-label="Open as full view"
          onclick={() => onPromote(pane)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <Maximize2 class="size-3.5" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          title="Close pane"
          aria-label="Close pane"
          onclick={() => onClose(i)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <X class="size-3.5" strokeWidth={1.5} />
        </button>
      </div>
      {@const View = entry.view}
      <View descriptor={pane} context={paneContext(pane, i)} {state} />
    </Pane>
  {/each}
</PaneGroup>
