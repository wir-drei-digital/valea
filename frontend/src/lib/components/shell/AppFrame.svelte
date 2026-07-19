<script lang="ts">
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';

  // Thin per-page composition of AppShell + Sidebar, shared by every route
  // beyond Today (which still wires this inline — see +page.svelte). Each
  // route just supplies `list` (optional) and `main`; the sidebar's ICM
  // project groups + active-mount highlighting are wired once here since
  // every route needs them.
  let {
    list,
    main,
    rail,
    mainVariant,
    onBeforeMutateActive
  }: {
    list?: Snippet;
    main: Snippet;
    rail?: Snippet;
    /** Forwarded to `AppShell` — see its doc comment. */
    mainVariant?: 'prose' | 'column';
    /** Forwarded to `Sidebar` — see `WorkspaceSwitcher`'s doc comment. */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  onMount(() => {
    void icmStore.refetch();
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

<AppShell {list} {main} {rail} {mainVariant}>
  {#snippet sidebar()}
    <Sidebar {activeMountKey} {onBeforeMutateActive} />
  {/snippet}
</AppShell>
