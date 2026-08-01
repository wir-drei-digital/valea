<script lang="ts">
  // The shell is now nav plus a CONTENT COLUMN, and the content column holds
  // the route's view. The nav is a full-height anchor, so everything else sits
  // BESIDE it rather than under it.
  //
  // `list` and `rail` are gone. `rail` was already dead code (forwarded by
  // `AppFrame`, passed by nobody); `list` is replaced by each pane's own
  // navigator — a Files pane carries its tree, a Chat pane its sessions, a
  // Mail pane its message list — which is what lets any view be rendered in
  // any pane. Routes that still want a fixed navigator column render it
  // inside their own `main` snippet, where it is theirs rather than the
  // shell's.
  //
  // The bottom bar is gone too, and with it the ＋ Pane menu: a pane is now
  // opened from the side you are already working on (mail's "Start a session",
  // the session header's "Open files", Knowledge's session picker), which is
  // what lets each control name an outcome instead of a kind.
  //
  // NAV COLLAPSE IS PARKED, NOT REMOVED (Daniel, 2026-08-01, after using it).
  // See `NAV_TOGGLE_PARKED` below — the three parts of that decision are next
  // to each other on purpose.
  //
  // Structurally there is ONE path, not two: every route renders through this
  // component, and a route that hosts no panes simply never has any.
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import NavToggle from './NavToggle.svelte';
  import { paneRoom } from '$lib/shell/pane-room.svelte';

  let { sidebar, main }: { sidebar: Snippet; main: Snippet } = $props();

  /**
   * The nav collapse is parked: the control is not rendered, everything behind
   * it stays live and tested — `valea.nav-visible`, `paneRoom.navVisible`, and
   * its part in `panesThatFit`'s arithmetic, which still subtracts the nav's
   * 236px on every "may another pane open".
   *
   * A FLAG, deliberately, rather than deleting the import and leaving
   * `NavToggle.svelte` referenced by nobody. Parked and orphaned look identical
   * to a dead-code sweep, and a sweep that deleted the component would very
   * likely take the reconciliation below with it — re-creating the trap it
   * exists to close. This way the two cannot be deleted independently: remove
   * the file and `bun run check` fails on line 1 of this import.
   *
   * Un-parking is deleting this constant, the `{#if}` it gates, and the
   * `onMount` below. Where the control should GO is the open question — see the
   * spec's "Opening a pane", which records why there is no universal "primary
   * pane header" to hang it on.
   */
  const NAV_TOGGLE_PARKED = true;

  // The other half of parking, and a trap closed rather than documented: with
  // nothing left to toggle it, a `false` persisted by an earlier build could no
  // longer be undone, so anyone who collapsed the nav while it WAS toggleable
  // would open the app to no navigation and nothing to bring it back.
  // Reconcile instead of stranding. Idempotent — after the first correction the
  // branch never runs — and it goes through `toggleNav`, so the preference, the
  // storage key and the fit arithmetic all stay exactly as they were.
  onMount(() => {
    if (NAV_TOGGLE_PARKED && !paneRoom.navVisible) paneRoom.toggleNav();
  });

  // The window measurement and the nav collapse both live in `paneRoom`, not
  // here. The collapse is persisted because every route mounts its own
  // AppShell (held in component state it would spring back open on the next
  // navigation, one click after the user asked for the width); the ROOM the
  // two of them add up to is shared because the controls that open panes are
  // owned by routes and views, and a gate only this component could see was a
  // gate they all walked past. See `pane-room.svelte.ts`.
  //
  // Width is consulted ONLY at the moment a pane would be added — never on
  // resize. Narrowing the window mounts and unmounts nothing; see
  // `pane-fit.ts`'s header for why continuous auto-hide is not implementable
  // without dropping a live session's channel.
  const navVisible = $derived(paneRoom.navVisible);
</script>

<svelte:window bind:innerWidth={paneRoom.width} />

<div class="bg-paper-surface text-ink-body flex h-screen">
  {#if navVisible}
    <aside class="border-paper-hairline bg-paper-sidebar w-[236px] shrink-0 border-r">
      {@render sidebar()}
    </aside>
  {/if}
  <div class={['flex min-w-0 flex-1 flex-col', NAV_TOGGLE_PARKED ? '' : 'relative']}>
    {#if !NAV_TOGGLE_PARKED}
      <NavToggle {navVisible} onToggle={() => paneRoom.toggleNav()} />
    {/if}
    <main class="flex min-h-0 min-w-0 flex-1 flex-col">{@render main()}</main>
  </div>
</div>
