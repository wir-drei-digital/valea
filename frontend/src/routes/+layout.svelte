<script lang="ts">
  import '@fontsource-variable/newsreader';
  import '@fontsource-variable/newsreader/wght-italic.css';
  import '@fontsource-variable/instrument-sans';
  import '@fontsource/ibm-plex-mono/400.css';
  import '@fontsource/ibm-plex-mono/500.css';
  import './layout.css';
  import { onMount } from 'svelte';
  import Onboarding from '$lib/components/onboarding/Onboarding.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { updatesStore } from '$lib/stores/updates.svelte';
  import { refreshSidebarProjectStores, wireIcmEvents } from '$lib/stores/icm.svelte';
  import SearchPalette from '$lib/components/palette/SearchPalette.svelte';

  let { children } = $props();

  // Joins `workspace:events` once, through the single `wireIcmEvents` call:
  // `icm_changed` keeps the sidebar tree live (Task 18 acceptance
  // criterion), and the `onWorkspace` pass-through re-syncs `workspaceStore`
  // on a `workspace` push (open/close, e.g. from another window) so this
  // window drops back to onboarding or picks up the newly-open one.
  //
  // Wired from `onMount` (not a state-dependent `$effect`) so this runs
  // exactly once per layout mount. `wireIcmEvents` is idempotent against
  // repeat calls, but calling it every time `workspaceStore.state` re-enters
  // 'open' (e.g. a workspace reopen) would still hit its "already wired"
  // branch and log a spurious console.warn on completely normal operation —
  // that warn is meant to flag a genuine second call site, not this one.
  onMount(() => {
    // COLD-LOAD bootstrap: `get_workspace` (via `workspaceStore.refresh()`)
    // is the ONLY way this window learns the current workspace on initial
    // load — `WorkspaceEventsChannel.join/3` pushes nothing on join, so the
    // `onWorkspace` handler below only ever fires on a LIVE switch (a
    // `workspace_opened`/`workspace_closed` broadcast), never now. The
    // sidebar's ICM project stores therefore refresh HERE once the
    // bootstrap resolves open; the switch path refreshes them from
    // `wireIcmEvents`'s own `onWorkspace` handler instead — see
    // `refreshSidebarProjectStores`'s doc comment (icm.svelte.ts) for the
    // two-call-site pattern.
    void workspaceStore.refresh().then(() => {
      if (workspaceStore.state === 'open') refreshSidebarProjectStores();
    });
    wireIcmEvents(() => {
      void workspaceStore.refresh();
    });

    // Auto-update polling — a no-op everywhere except the packaged desktop
    // app (see `updatesSupported`), so browser dev and vitest never start
    // timers. Idempotent, and the root layout never unmounts, so no cleanup.
    updatesStore.start();
  });
</script>

{#if workspaceStore.state === 'loading'}
  <div class="flex min-h-screen items-center justify-center bg-paper-surface"></div>
{:else if workspaceStore.state === 'none'}
  <Onboarding />
{:else}
  {@render children()}
  <SearchPalette />
{/if}
