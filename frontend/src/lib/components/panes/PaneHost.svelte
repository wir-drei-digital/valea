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

  // Only ever fired with two panes on a real split; the single-pane layout is
  // `[100]`, which the length guard ignores so closing a pane can't overwrite
  // the ratio the user dragged. The finite guard keeps `savePaneSplit` from
  // ever persisting the string "NaN".
  function onLayoutChange(layout: number[]): void {
    const primarySize = layout[0];
    if (layout.length === 2 && Number.isFinite(primarySize)) savePaneSplit(primarySize);
  }
</script>

<!--
  The PaneGroup and the primary Pane are UNCONDITIONAL, and only the resizer +
  side pane are conditional. This is load-bearing, not stylistic: Svelte's
  `{#if}`/`{:else}` branches are separate effect trees, so hosting the primary
  in one branch and bare in the other would destroy and rebuild it on every
  pane open and close — tearing down the open session's channel (join/leave
  churn `ChatView`'s own header comment forbids), dropping the composer's
  unsent draft, and replaying the transcript from the top. Opening a file from
  a tool chip mid-draft has to be free. paneforge supports panes coming and
  going (`order` pins the primary first regardless of mount timing), and a
  lone pane always lays out at 100% — it has no `defaultSize`, so the group's
  default layout gives it everything left over.
-->
<PaneGroup direction="horizontal" class="min-h-0 flex-1" {onLayoutChange}>
  <Pane order={1} minSize={30} class="flex min-h-0 min-w-0 flex-col">
    {@render primary()}
  </Pane>
  {#if active}
    {@const PaneView = paneComponents[active.kind]}
    <!-- Read once per pane-OPEN (a `@const` with no reactive dependency
         computes once per block instance), not once per PaneHost: closing and
         reopening a pane in the same route visit keeps the ratio the user just
         dragged. Sized from the side, so the primary stays default-less. -->
    {@const sideSplit = 100 - loadPaneSplit()}
    <PaneResizer
      aria-label="Resize pane"
      class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
    />
    <Pane
      order={2}
      defaultSize={sideSplit}
      minSize={30}
      class="bg-paper-panel flex min-h-0 min-w-0 flex-col"
    >
      <!-- Same vertical band as the chat header and the Context rail header
           (pt-3 + 24px content row + pb-2), so all three border-b lines read
           as one continuous rule across the pane. size-8/-my-1.5 buttons:
           ≥32px hit targets without growing the band. -->
      <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 pt-3 pb-2">
        <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
          {paneTitle(active)}
        </span>
        <button
          type="button"
          title="Open as full view"
          aria-label="Open as full view"
          onclick={() => onPromote(active)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <Maximize2 class="size-3.5" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          title="Close pane"
          aria-label="Close pane"
          onclick={onClose}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <X class="size-3.5" strokeWidth={1.5} />
        </button>
      </div>
      {#key paneKey}
        <PaneView descriptor={active} context={paneContext} />
      {/key}
    </Pane>
  {/if}
</PaneGroup>
