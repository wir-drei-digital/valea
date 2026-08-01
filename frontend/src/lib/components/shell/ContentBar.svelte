<script lang="ts">
  /**
   * The content area's bottom band: nav collapse at the far left, ＋ Pane at
   * the right. It sits BESIDE the nav, never under it — the nav is a
   * full-height anchor — which is why it lives inside `AppShell`'s content
   * column rather than across the window.
   *
   * Styling is deliberately furniture, not feature. **No accent colour**: in
   * this design system colour means consequence (PRODUCT.md principle 1) and
   * opening a view has none. Inactive `text-ink-meta`, active
   * `text-ink-heading`, `bg-paper-sidebar` under a `border-t` hairline.
   *
   * The band is 28px but every control is 32px — the hit target is what
   * matters, so the buttons overhang the band by 2px on each side rather than
   * shrinking to fit it.
   *
   * `onOpen` absent means this route is not a pane host (Today, Tasks,
   * Calendar, Audit, Sources): the bar still renders, as stable furniture
   * rather than chrome that appears and disappears as you navigate, but it
   * offers no ＋.
   */
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import Plus from '@lucide/svelte/icons/plus';
  import Check from '@lucide/svelte/icons/check';
  import type { MenuItem } from '$lib/shell/content-bar';
  import type { PaneDescriptor } from '$lib/panes/pane-route';

  let {
    items = [],
    onOpen,
    canAddPane = false,
    addPaneReason = null,
    navVisible = true,
    onToggleNav
  }: {
    items?: MenuItem[];
    /** Absent on a route that hosts no panes — the ＋ is not rendered at all. */
    onOpen?: (d: PaneDescriptor) => void;
    canAddPane?: boolean;
    /** Why another pane will not fit, shown on hover when `canAddPane` is false. */
    addPaneReason?: string | null;
    navVisible?: boolean;
    onToggleNav: () => void;
  } = $props();

  const BUTTON =
    'text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-0.5 flex h-8 items-center gap-1.5 rounded-md px-2 text-[11.5px] transition-colors outline-none focus-visible:ring-2';
</script>

<div
  class="border-paper-hairline bg-paper-sidebar flex h-7 shrink-0 items-center gap-1 border-t px-1.5"
>
  <button
    type="button"
    onclick={onToggleNav}
    title={navVisible ? 'Hide navigation' : 'Show navigation'}
    aria-label={navVisible ? 'Hide navigation' : 'Show navigation'}
    aria-pressed={!navVisible}
    class={[BUTTON, navVisible ? '' : 'text-ink-heading']}
  >
    <PanelLeft class="size-3.5" strokeWidth={1.5} />
  </button>

  <span class="min-w-0 flex-1" aria-hidden="true"></span>

  {#if onOpen}
    {#if canAddPane}
      <DropdownMenu.Root>
        <DropdownMenu.Trigger>
          {#snippet child({ props })}
            <button
              type="button"
              {...props}
              aria-label="Open another view beside this one"
              class={[BUTTON, 'data-[state=open]:bg-paper-pill data-[state=open]:text-ink-heading']}
            >
              <Plus class="size-3.5" strokeWidth={1.5} />
              Pane
            </button>
          {/snippet}
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="end" side="top" class="w-56">
          {#each items as item (item.kind)}
            <!-- A kind already on screen is CHECKED and inert rather than
                 hidden, and an unavailable one carries its reason: "No mail
                 account yet" teaches something, a missing row does not. -->
            <DropdownMenu.Item
              disabled={item.descriptor === null}
              onSelect={() => item.descriptor && onOpen?.(item.descriptor)}
            >
              {#if item.disabledReason === 'Already open'}
                <Check class="size-3.5" strokeWidth={1.5} />
              {/if}
              {item.label}
              {#if item.disabledReason && item.disabledReason !== 'Already open'}
                <span class="text-ink-meta ms-auto text-[10.5px]">{item.disabledReason}</span>
              {/if}
            </DropdownMenu.Item>
          {/each}
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    {:else}
      <!-- `aria-disabled`, not `disabled`: a truly disabled button takes no
           pointer events, so its `title` never appears — which would turn
           "disabled with the reason on hover" straight back into the silent
           no-op the spec rejects. It stays focusable, so a keyboard user can
           reach the reason too. -->
      <button
        type="button"
        aria-disabled="true"
        title={addPaneReason ?? 'No room for another pane'}
        aria-label={`Open another view beside this one — unavailable: ${addPaneReason ?? 'no room for another pane'}`}
        onclick={(event) => event.preventDefault()}
        class={[BUTTON, 'cursor-default hover:bg-transparent hover:text-ink-meta']}
      >
        <Plus class="size-3.5 opacity-50" strokeWidth={1.5} />
        <span class="opacity-50">Pane</span>
      </button>
    {/if}
  {/if}
</div>
