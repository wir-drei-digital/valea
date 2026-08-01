<script lang="ts">
  // The shell is now nav plus a CONTENT COLUMN, and the content column holds
  // the route's pane row and the bar beneath it. The nav is a full-height
  // anchor, so the bar sits BESIDE it rather than under it.
  //
  // `list` and `rail` are gone. `rail` was already dead code (forwarded by
  // `AppFrame`, passed by nobody); `list` is replaced by each pane's own
  // navigator — a Files pane carries its tree, a Chat pane its sessions, a
  // Mail pane its message list — which is what lets any view be rendered in
  // any pane. Routes that still want a fixed navigator column render it
  // inside their own `main` snippet, where it is theirs rather than the
  // shell's.
  //
  // Structurally there is ONE path, not two: every route renders through this
  // component, and a route that hosts no panes simply never has any. It still
  // gets the bar, as stable furniture rather than chrome that appears and
  // disappears as you navigate.
  import type { Snippet } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import ContentBar from './ContentBar.svelte';
  import { menuItems } from '$lib/shell/content-bar';
  import { paneRoom } from '$lib/shell/pane-room.svelte';
  import { dedupeSurfaces, parsePanes, withPanes, type PaneDescriptor } from '$lib/panes/pane-route';
  import { routeKeyFor } from '$lib/panes/pane-memory';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';

  let {
    sidebar,
    main,
    primaryDescriptor = null
  }: {
    sidebar: Snippet;
    main: Snippet;
    /**
     * What the route's own primary view is showing, so the ＋ Pane menu can
     * mark that kind as already open and `dedupeSurfaces` can keep a second
     * surface of it from opening beside it. `null` on a route whose primary
     * names no surface.
     */
    primaryDescriptor?: PaneDescriptor | null;
  } = $props();

  // Whether this route hosts panes at all is `routeKeyFor`'s question, and it
  // is the same list `pane-memory` keys on — chat, mail, knowledge. Deriving
  // it here rather than taking a prop keeps `primaryDescriptor = null` (the
  // Knowledge index) distinguishable from "not a pane host" without a second
  // flag that could disagree with the first.
  const isPaneHost = $derived(routeKeyFor(page.url.pathname) !== null);
  const panes = $derived(parsePanes(page.url.searchParams));

  // The window measurement and the nav collapse both live in `paneRoom`, not
  // here. The collapse is persisted because every route mounts its own
  // AppShell (held in component state it would spring back open on the next
  // navigation, one click after the user asked for the width); the ROOM the
  // two of them add up to is shared because route-owned controls open panes
  // too, and a gate only this component could see was a gate they all walked
  // past. See `pane-room.svelte.ts`.
  const navVisible = $derived(paneRoom.navVisible);

  // Width is consulted ONLY here and at the other pane-opening controls, at
  // the moment a pane would be added — never on resize. Narrowing the window
  // mounts and unmounts nothing; see `pane-fit.ts`'s header for why continuous
  // auto-hide is not implementable without dropping a live session's channel.
  const canAddPane = $derived(isPaneHost && paneRoom.canAdd(panes.length));
  const addPaneReason = $derived(paneRoom.reasonFor(panes.length));

  const enabledMountKeys = $derived(
    mountsStore.mounts.filter((m) => m.enabled && !m.degraded).map((m) => m.mountKey)
  );

  // Preferred account FIRST — `menuItems` opens on `mailAccounts[0]`, and the
  // mailbox the user is reading is the one they mean.
  const mailAccounts = $derived.by(() => {
    const all = mailStore.accounts.map((a) => a.account);
    const selected = mailStore.selectedAccount;
    return selected && all.includes(selected)
      ? [selected, ...all.filter((a) => a !== selected)]
      : all;
  });

  const openKinds = $derived([
    ...(primaryDescriptor ? [primaryDescriptor.kind] : []),
    ...panes.map((p) => p.kind)
  ]);

  const items = $derived(
    menuItems({
      icmParam: page.url.searchParams.get('icm'),
      enabledMountKeys,
      mailAccounts,
      mailStatusLoaded: mailStore.statusLoaded,
      openKinds
    })
  );

  /**
   * Appending a pane is the shell's job, not the route's — every pane host
   * would otherwise write the same line. `dedupeSurfaces` allocates, so
   * `PaneHost` always receives a FRESH array and re-derives its row layout;
   * a same-identity array with mutated contents silently reinstates the bug
   * where a dragged ratio is written back over.
   */
  function openPane(d: PaneDescriptor): void {
    void goto(withPanes(page.url, dedupeSurfaces(primaryDescriptor, [...panes, d])), {
      keepFocus: true,
      noScroll: true
    });
  }
</script>

<svelte:window bind:innerWidth={paneRoom.width} />

<div class="bg-paper-surface text-ink-body flex h-screen">
  {#if navVisible}
    <aside class="border-paper-hairline bg-paper-sidebar w-[236px] shrink-0 border-r">
      {@render sidebar()}
    </aside>
  {/if}
  <div class="flex min-w-0 flex-1 flex-col">
    <main class="flex min-h-0 min-w-0 flex-1 flex-col">{@render main()}</main>
    <ContentBar
      {items}
      onOpen={isPaneHost ? openPane : undefined}
      {canAddPane}
      {addPaneReason}
      {navVisible}
      onToggleNav={() => paneRoom.toggleNav()}
    />
  </div>
</div>
