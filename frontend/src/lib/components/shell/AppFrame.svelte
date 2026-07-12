<script lang="ts">
  import type { Snippet } from 'svelte';
  import { onMount } from 'svelte';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { icmToNav } from '$lib/shell/nav';

  // Thin per-page composition of AppShell + Sidebar, shared by every route
  // beyond Today (which still wires this inline — see +page.svelte). Each
  // route just supplies `list` (optional) and `main`; the sidebar's live ICM
  // nav is wired once here since every route needs it.
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
    /** Forwarded to `Sidebar`/`IcmTree` — see `IcmTree.svelte`'s doc comment. */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  onMount(() => {
    void icmStore.refetch();
  });

  const icmNav = $derived(icmToNav(icmStore.nodes));
</script>

<AppShell {list} {main} {rail} {mainVariant}>
  {#snippet sidebar()}
    <Sidebar workspaceName={workspaceStore.name ?? 'Workspace'} {icmNav} {onBeforeMutateActive} />
  {/snippet}
</AppShell>
