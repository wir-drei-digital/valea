<script lang="ts">
  /**
   * PARKED, NOT RENDERED (Daniel, 2026-08-01, after using it): the control is
   * out of the UI for now, while everything behind it stays live —
   * `valea.nav-visible`, `paneRoom.navVisible` and its part in `panesThatFit`.
   * A hidden nav is still a wider row, and every refusal still counts it. This
   * file is kept because the decision was about PLACEMENT, not the feature.
   *
   * NOT ORPHANED — do not sweep it. `AppShell` imports this component and gates
   * it behind `NAV_TOGGLE_PARKED`, so the reference is real and deleting this
   * file breaks the build there. Read that constant's comment before touching
   * either: the same decision also put a nav-visible RECONCILIATION in
   * `AppShell`'s `onMount`, and deleting this without it strands anyone who had
   * collapsed the nav while the control still existed.
   *
   * Collapse/restore the navigation. It used to sit at the far left of the
   * content area's bottom bar; the bar is retired, so it moved to the TOP left
   * of the content column — the same edge, against the nav, where the primary
   * pane's own header band starts.
   *
   * Absolutely positioned rather than laid out in the flow, and that is the
   * whole reason it can be here at all: every route's top-left is different (a
   * tab strip, a list-pane title, a session's folder line, a prose column), and
   * a control in the flow would have to be threaded through nine routes and two
   * shared components, each free to forget it. One control, one owner, one
   * physical place. Routes whose first row would sit underneath it carry a left
   * gutter instead — see the `gutter` props on `SessionHeader` and `ListPane`.
   *
   * It moves with the content column, so it is against the nav's inner edge
   * when the nav is shown and against the window when it is hidden — the same
   * relationship the bar's copy of it had. A control INSIDE the nav would
   * vanish with the nav and strand the user.
   *
   * Furniture, not feature: no accent colour (colour means consequence), 32px
   * hit target, `aria-pressed` naming the collapsed state.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';

  let { navVisible, onToggle }: { navVisible: boolean; onToggle: () => void } = $props();
</script>

<button
  type="button"
  onclick={onToggle}
  title={navVisible ? 'Hide navigation' : 'Show navigation'}
  aria-label={navVisible ? 'Hide navigation' : 'Show navigation'}
  aria-pressed={!navVisible}
  class={[
    'text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 absolute top-2 left-1.5 z-30 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2',
    navVisible ? '' : 'text-ink-heading'
  ]}
>
  <PanelLeft class="size-3.5" strokeWidth={1.5} />
</button>
