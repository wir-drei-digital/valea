<script lang="ts">
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';
  import type { PaneDescriptor } from '$lib/panes/pane-route';

  // Thin per-page composition of AppShell + Sidebar, shared by every route
  // beyond Today (which still wires this inline — see +page.svelte). Each
  // route supplies `main` and, if it hosts panes, the descriptor its own
  // primary view is showing; the sidebar's ICM project groups +
  // active-mount highlighting are wired once here since every route needs
  // them.
  //
  // `list` and `rail` are gone — see `AppShell`'s header. A route that wants
  // a fixed navigator column renders it inside its own `main` snippet.
  let {
    main,
    primaryDescriptor = null,
    onBeforeMutateActive
  }: {
    main: Snippet;
    /** Forwarded to `AppShell` — what the route's primary view is showing. */
    primaryDescriptor?: PaneDescriptor | null;
    /** Forwarded to `Sidebar` — see `WorkspaceSwitcher`'s doc comment. */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  onMount(() => {
    void icmStore.refetch();
    // The ＋ Pane menu reasons about mounts and mail accounts from EVERY
    // route, not just the two that own those stores, and it must only ever
    // assert availability from LOADED data — an unfetched store looks
    // identical to an empty workspace. Both are one-shot: the routes that own
    // them refresh unconditionally on their own mount, so this is the cold
    // path only.
    if (!mountsStore.loaded) void mountsStore.refresh();
    if (!mailStore.statusLoaded) void mailStore.refreshStatus();
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

<AppShell {main} {primaryDescriptor}>
  {#snippet sidebar()}
    <Sidebar {activeMountKey} {onBeforeMutateActive} />
  {/snippet}
</AppShell>
