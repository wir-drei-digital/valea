<script lang="ts">
  // Renders the route's primary view alone, or split with ONE side pane
  // (side-panes pass; deliberately not a tiling manager). The pane slot is
  // registry-driven; chrome = title, promote ("open as full view"), close.
  //
  // The host owns NO pane state: which pane is open is the route's `?pane=`
  // param (`pane-route.ts`), and every button here just calls back up. The
  // only thing PaneHost persists is the split ratio (`pane-split.ts`).
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import type { Snippet } from 'svelte';
  import { panesEqual, paneTitle, serializePaneParam, type PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import { paneComponents } from '$lib/panes/registry';
  import { loadPaneSplit, savePaneSplit } from '$lib/panes/pane-split';
  import X from '@lucide/svelte/icons/x';
  import Maximize2 from '@lucide/svelte/icons/maximize-2';

  let {
    primary,
    primaryDescriptor = null,
    pane = null,
    paneContext,
    onClose,
    onPromote
  }: {
    primary: Snippet;
    primaryDescriptor?: PaneDescriptor | null;
    pane?: PaneDescriptor | null;
    paneContext: PaneContext;
    onClose: () => void;
    onPromote: (d: PaneDescriptor) => void;
  } = $props();

  // A pane duplicating the primary view renders nothing (pane-route doc).
  // `pane` is already null for an absent/invalid `?pane=` — `parsePaneParam`
  // fails closed — so this one guard covers all three "primary alone" cases.
  const active = $derived(pane && !panesEqual(pane, primaryDescriptor) ? pane : null);

  // Remount key. Deliberately the SERIALIZED descriptor, not the object:
  // hosts re-derive the descriptor from `page.url` on every navigation, so a
  // fresh object identity means nothing (switching `?session=` beside an open
  // file pane must not tear the file down and refetch it). A real identity
  // change — including the `chat-new` -> `chat:<id>` rewrite, which must
  // remount so the new ChatView fires the stashed initial prompt — changes
  // this string.
  const paneKey = $derived(active ? serializePaneParam(active) : '');

  // Layout is a percent array summing to 100; paneforge also fires this once
  // on mount with the default layout (a harmless idempotent re-save). The
  // finite guard keeps `savePaneSplit` from ever persisting the string "NaN".
  function onLayoutChange(layout: number[]): void {
    const primarySize = layout[0];
    if (layout.length === 2 && Number.isFinite(primarySize)) savePaneSplit(primarySize);
  }
</script>

{#if active}
  {@const PaneView = paneComponents[active.kind]}
  <!-- Read once per pane-open, not once per PaneHost: closing and reopening
       a pane in the same route visit keeps the ratio the user just dragged. -->
  {@const initialSplit = loadPaneSplit()}
  <PaneGroup direction="horizontal" class="min-h-0 flex-1" {onLayoutChange}>
    <Pane defaultSize={initialSplit} minSize={30} class="flex min-h-0 min-w-0 flex-col">
      {@render primary()}
    </Pane>
    <PaneResizer
      aria-label="Resize pane"
      class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
    />
    <Pane minSize={30} class="bg-paper-panel flex min-h-0 min-w-0 flex-col">
      <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
        <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] font-medium">
          {paneTitle(active)}
        </span>
        <button
          type="button"
          title="Open as full view"
          aria-label="Open as full view"
          onclick={() => onPromote(active)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-6 items-center justify-center rounded-md transition-colors"
        >
          <Maximize2 class="size-3.5" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          title="Close pane"
          aria-label="Close pane"
          onclick={onClose}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-6 items-center justify-center rounded-md transition-colors"
        >
          <X class="size-3.5" strokeWidth={1.5} />
        </button>
      </div>
      {#key paneKey}
        <PaneView descriptor={active} context={paneContext} />
      {/key}
    </Pane>
  </PaneGroup>
{:else}
  {@render primary()}
{/if}
