<script lang="ts">
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';

  // Thin per-page composition of AppShell + Sidebar, shared by every route
  // beyond Today (which still wires this inline — see +page.svelte). Each
  // route supplies `main`; the sidebar's ICM project groups + active-mount
  // highlighting are wired once here since every route needs them.
  //
  // `list` and `rail` are gone — see `AppShell`'s header. A route that wants
  // a fixed navigator column renders it inside its own `main` snippet.
  //
  // `primaryDescriptor` is gone with the ＋ Pane menu, which was the only
  // thing the shell ever did with it — every route still computes its own and
  // hands it to `PaneHost`, where it belongs.
  let {
    main,
    onBeforeMutateActive
  }: {
    main: Snippet;
    /** Forwarded to `Sidebar` — see `WorkspaceSwitcher`'s doc comment. */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  onMount(() => {
    void icmStore.refetch();
    // A mounted `ChatView` names the ICM a session runs in out of
    // `mountsStore`, on any route that can host one, so the cold fetch stays
    // here rather than in the two routes that own the store. One-shot: those
    // routes refresh unconditionally on their own mount.
    //
    // The mail-status cold fetch that used to sit beside it went with the
    // ＋ Pane menu — the only consumer that needed mail loaded on routes that
    // show no mail. `MailPane` and `/mail` each ask for themselves.
    if (!mountsStore.loaded) void mountsStore.refresh();
  });

  // Task 9.3: the sidebar no longer renders a file tree (Knowledge owns
  // that now) — it renders one row per ICM project (`IcmProjects.svelte`).
  // `activeMountKey` (Task 9.4) tells it which row corresponds to the
  // current route, derived from route state alone — see
  // `resolveActiveMountKey`'s doc comment in `icm-route.ts` for the exact
  // per-route rule (path-based on `/knowledge/<mountKey>/...`, session-owner
  // lookup on `/chat?session=`, `?icm=` everywhere else).
  const activeMountKey = $derived(
    resolveActiveMountKey(page.url.pathname, page.url.searchParams, recentSessionsStore.groups)
  );
</script>

<AppShell {main}>
  {#snippet sidebar()}
    <Sidebar {activeMountKey} {onBeforeMutateActive} />
  {/snippet}
</AppShell>
