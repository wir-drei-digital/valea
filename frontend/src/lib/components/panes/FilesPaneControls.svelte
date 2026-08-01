<script lang="ts">
  /**
   * Everything in the Files pane's header band: the TAB STRIP, then Compare and
   * the tree toggle. `PaneHost` renders this inside the shared pane header, so
   * the pane has one header, one close button, and per-kind extras.
   *
   * The strip lives here rather than above the content because two stacked
   * bands were two horizontal rules where the rest of the app has one, and a
   * pane title above a tab naming the same file said it twice. The registry
   * entry's `ownsTitle` is what suppresses that title — see `registry.ts`.
   *
   * State is created by the host and shared with the body; neither component
   * parents the other, and every action that rewrites the descriptor is a
   * handler the BODY registered, because only the body holds `PaneContext`.
   *
   * No accent colour: in this design system colour means consequence, and
   * switching a tab or showing a navigator has none. Every state here reads as
   * ink weight and paper instead.
   *
   * There is deliberately no "open a file" control. A header button has no file
   * to name, so it could only guess one. The tree row's "Open in a new tab"
   * names the file the user actually wants; ＋ opens an empty tab and lets them
   * pick.
   *
   * COMPARE is the exception, and the reason it belongs here rather than in the
   * strip: it names no file at all. It puts the tab you are reading beside the
   * one you were reading before it, which is a property of the pane, not of any
   * row. It is also the last control in this feature that depends on a width,
   * because two columns genuinely do compete for the content area.
   *
   * Both pressed states read what is RENDERED (`treeShown`, `compareShown`),
   * never the preference or the descriptor: the body drops the tree when the
   * pane is too narrow to hold it beside a file, and falls back to one column
   * when two will not fit. A button announcing `aria-pressed="true"` over
   * something that is not on screen is a worse failure than a disabled one.
   */
  import Columns2 from '@lucide/svelte/icons/columns-2';
  import PanelRight from '@lucide/svelte/icons/panel-right';
  import Plus from '@lucide/svelte/icons/plus';
  import X from '@lucide/svelte/icons/x';
  import type { FilesPaneDescriptor } from '$lib/panes/pane-route';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  // The prop is `state` (PaneHost's contract) but the local binding is not:
  // Svelte reads `$state` as a store subscription on a local called `state`,
  // so the two cannot coexist in one component. Same rename `FilesPane` makes,
  // for the same reason; the prop name the host passes is unchanged.
  let {
    descriptor,
    state: pane
  }: { descriptor: FilesPaneDescriptor; state: FilesPaneState } = $props();

  const treeLabel = $derived(
    pane.treeBlocked
      ? `Show the file tree — unavailable: ${pane.treeBlocked.toLowerCase()}`
      : pane.treeShown
        ? 'Hide the file tree'
        : 'Show the file tree'
  );

  const compareLabel = $derived(
    pane.compareBlocked
      ? `Compare two files — unavailable: ${pane.compareBlocked.toLowerCase()}`
      : pane.compareShown
        ? 'Stop comparing'
        : 'Compare two files'
  );

  function basename(path: string): string {
    return path.split('/').pop() ?? path;
  }

  /**
   * The scrolling chip list, so the strip can hold the active tab in view.
   *
   * Scrolling is the price of a floor: chips stop shrinking at `min-w-[88px]`,
   * and a strip too narrow for all of them scrolls rather than crushing. What
   * it replaces was worse — chips shrank without limit while the label button
   * kept a hard padding floor it could not go under, so below that floor the
   * button OVERFLOWED its own chip and painted over its neighbours. At a 310px
   * pane with six tabs the chips were 14px and every label overhung by 28,
   * which is an unreadable smear rather than a tight strip.
   */
  let strip = $state<HTMLElement | null>(null);
  /**
   * Bound, not measured on demand, because the strip narrowing is one of the
   * ways the active tab leaves the screen: drag the row's resizer with the
   * sixth tab open and the one you are reading slides out from under you.
   */
  let stripWidth = $state(0);

  $effect(() => {
    // Named reads, not incidental ones: this must re-run when the active tab
    // changes, when tabs are added or removed, when the pending tab takes over
    // as the current chip, and when the strip itself is resized.
    void descriptor.active;
    void descriptor.paths.length;
    void pane.pendingTab;
    void stripWidth;

    const box = strip;
    const chip = box?.querySelector<HTMLElement>('[data-tab-current="true"]');
    if (!box || !chip) return;

    // RECTS, not `offsetLeft`. Nothing between a chip and the scroll box is
    // positioned, so a chip's `offsetParent` is some ancestor several levels up
    // and `offsetLeft` is not a coordinate in this box at all. Measured live it
    // read 908 inside a box whose entire scroll width is 548 — so the "is it
    // off the right edge" branch was always true, and this effect scrolled the
    // strip to its far end, hiding the very tab it exists to reveal.
    const boxRect = box.getBoundingClientRect();
    const chipRect = chip.getBoundingClientRect();
    const left = chipRect.left - boxRect.left + box.scrollLeft;
    const right = left + chipRect.width;

    // Deliberately NOT `scrollIntoView`: that walks every scrollable ancestor,
    // and the transcript or the file body beside this pane is one of them. Only
    // the strip is allowed to move.
    if (left < box.scrollLeft) box.scrollLeft = left;
    else if (right > box.scrollLeft + box.clientWidth) box.scrollLeft = right - box.clientWidth;
  });
</script>

<!-- The strip takes the title's place and its width. Chips are `h-8`, and the
     `-my-1` on this container is what makes the whole thing a 24px margin box —
     the same height a `leading-6` pane title has, so the header rule across a
     multi-pane row lines up with Chat's and Mail's.
     It was `-my-1.5`, matching the header's own icon buttons, and that was
     wrong for this one band: dropping the title (`ownsTitle`) removed the only
     24px element, so the Files band measured 41px against every other kind's
     45 and the "one continuous line" this band exists for was visibly broken. -->
<div class="-my-1 flex min-w-0 flex-1 items-center gap-1" aria-label="Open files">
  <!-- `py-1 -my-1`: the scroll box keeps 4px of internal room so a chip's focus
       ring is not clipped by its own overflow, while still presenting a 32px
       margin box to the container above. `overflow-x` forces `overflow-y` to
       match, so the room has to be made rather than asked for. The scrollbar is
       hidden because a classic one would eat a third of a 24px band; the strip
       is dragged by its content, and the active chip is scrolled in by the
       effect above. -->
  <div
    bind:this={strip}
    bind:clientWidth={stripWidth}
    class="-my-1 flex min-w-0 flex-1 items-center gap-1 overflow-x-auto py-1 [scrollbar-width:none] [&::-webkit-scrollbar]:hidden"
  >
    {#if descriptor.paths.length === 0 && !pane.pendingTab}
      <!-- Nothing open: the pane still has to say what it is. Same typography as
           the title `PaneHost` renders for every other kind. -->
      <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
        Files
      </span>
    {/if}

    {#each descriptor.paths as path, i (path)}
    <!-- "Showing" is what is ON SCREEN: the active tab, plus the compare
         partner while two columns are rendered, and NEITHER while a pending tab
         holds the content area. -->
      {@const showing =
        !pane.pendingTab &&
        (i === descriptor.active || (pane.compareShown && i === descriptor.compare))}
      <!-- `min-w-[88px]` is the floor that makes overflow structurally
           impossible rather than merely unlikely: no chip can be narrower than
           the label button's own padding, so the button can never overhang the
           chip and paint over its neighbour. Above it, `flex-1` still lets
           chips share the strip up to `max-w-[180px]`. -->
      <div
        data-tab-current={!pane.pendingTab && i === descriptor.active ? 'true' : undefined}
        class={[
          'group/tab relative flex h-8 min-w-[88px] max-w-[180px] flex-1 shrink items-center rounded-md transition-colors',
          showing ? 'bg-paper-card' : 'hover:bg-paper-pill'
        ]}
      >
        <!-- Plain buttons rather than a `tablist`: these tabs own no `tabpanel`
             to point at, and claiming the role would promise the arrow-key
             navigation the APG pattern requires. `aria-current` is the same
             marker `IcmTree` uses for the row you are reading.

             `h-full` rather than `py-1.5`: the button was 30px inside a 32px
             chip, the one hit target in this band under the floor.

             ONLY the showing chip reserves `pr-8` for its ✕. A non-active chip
             pays `pr-2.5`, which is 22px more name at every width and drops the
             chip's own floor — the reservation is what made a crushed chip
             overflow, and reserving it on a tab you are not reading buys
             nothing. Its ✕ overlays the name's tail on hover instead, which is
             `bg-inherit`'s whole purpose. -->
        <button
          type="button"
          title={path}
          aria-current={!pane.pendingTab && i === descriptor.active ? 'true' : undefined}
          onclick={() => pane.showTab?.(i)}
          class={[
            'focus-visible:ring-ring/50 h-full min-w-0 flex-1 truncate rounded-md pl-2.5 text-left text-[12px] transition-colors outline-none focus-visible:ring-2',
            showing ? 'text-ink-heading pr-8' : 'text-ink-meta group-hover/tab:text-ink-heading pr-2.5'
          ]}
        >
          {basename(path)}
        </button>
        <!-- A sibling of the tab button, never nested inside it: a button within a
             button is invalid HTML and swallows the outer click target.
             `bg-inherit` takes the chip's own background so the ✕ sits cleanly
             over the truncated end of a long name. -->
        <button
          type="button"
          title="Close tab"
          aria-label={`Close ${basename(path)}`}
          onclick={() => pane.closeTab?.(i)}
          class={[
            'text-ink-meta hover:text-ink-heading focus-visible:ring-ring/50 absolute top-0 right-0 flex size-8 items-center justify-center rounded-r-md bg-inherit transition-colors outline-none focus-visible:opacity-100 focus-visible:ring-2',
            showing ? 'opacity-100' : 'opacity-0 group-hover/tab:opacity-100'
          ]}
        >
          <X class="size-3" strokeWidth={1.5} />
        </button>
      </div>
    {/each}

    {#if pane.pendingTab}
      <div
        data-tab-current="true"
        class="bg-paper-card group/tab relative flex h-8 min-w-[88px] max-w-[180px] flex-1 shrink items-center rounded-md"
      >
        <span
          class="text-ink-meta min-w-0 flex-1 truncate py-1.5 pr-8 pl-2.5 text-[12px] italic"
          aria-current="true"
        >
          New tab
        </span>
        <button
          type="button"
          title="Close tab"
          aria-label="Close the new tab"
          onclick={() => (pane.pendingTab = false)}
          class="text-ink-meta hover:text-ink-heading focus-visible:ring-ring/50 absolute top-0 right-0 flex size-8 items-center justify-center rounded-r-md bg-inherit transition-colors outline-none focus-visible:ring-2"
        >
          <X class="size-3" strokeWidth={1.5} />
        </button>
      </div>
    {/if}
  </div>

  <!-- OUTSIDE the scroll box: ＋ is how you get a seventh tab, and a control
       that scrolls away with the sixth is a control you cannot reach. -->
  <button
    type="button"
    title="New tab"
    aria-label="New tab"
    onclick={() => (pane.pendingTab = true)}
    class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
  >
    <Plus class="size-3.5" strokeWidth={1.5} />
  </button>
</div>

<!-- Same `aria-disabled` rule as the tree toggle below. The guard lives in the
     body's `toggleCompare`, which covers pointer and keyboard alike. -->
<button
  type="button"
  title={pane.compareBlocked ?? (pane.compareShown ? 'Stop comparing' : 'Compare two files')}
  aria-label={compareLabel}
  aria-pressed={pane.compareShown}
  aria-disabled={pane.compareBlocked ? 'true' : undefined}
  onclick={() => pane.toggleCompare?.()}
  class={[
    'refusable hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    pane.compareShown ? 'text-ink-heading' : 'text-ink-meta hover:text-ink-heading'
  ]}
>
  <Columns2 class="size-3.5" strokeWidth={1.5} />
</button>

<!-- `aria-disabled`, not the `disabled` attribute — the same rule the tree row's
     "Open in a new tab" and the bar's ＋ Pane follow: a truly disabled button
     takes no pointer events, so its `title` never appears, and it leaves the tab
     order entirely, so a keyboard or screen-reader user could never reach the
     reason. The click guard lives in `toggleTree`, which covers pointer and
     keyboard activation alike. -->
<button
  type="button"
  title={pane.treeBlocked ?? (pane.treeShown ? 'Hide the file tree' : 'Show the file tree')}
  aria-label={treeLabel}
  aria-pressed={pane.treeShown}
  aria-disabled={pane.treeBlocked ? 'true' : undefined}
  onclick={() => pane.toggleTree()}
  class={[
    'refusable hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 shrink-0 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    pane.treeShown ? 'text-ink-heading' : 'text-ink-meta hover:text-ink-heading'
  ]}
>
  <!-- `PanelRight`, because that is the edge the tree is on now. -->
  <PanelRight class="size-3.5" strokeWidth={1.5} />
</button>
