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
  import { wireIcmEvents } from '$lib/stores/icm.svelte';

  let { children } = $props();

  // Joins `workspace:events` once the workspace is open, through the single
  // `wireIcmEvents` call: `icm_changed` keeps the sidebar tree live (Task 18
  // acceptance criterion), and the `onWorkspace` pass-through re-syncs
  // `workspaceStore` on a `workspace` push (open/close, e.g. from another
  // window) so this window drops back to onboarding or picks up the
  // newly-open one. `wireIcmEvents` is idempotent, so this is safe to call
  // from an `$effect` that reruns.
  function wireWorkspaceEvents() {
    wireIcmEvents(() => {
      void workspaceStore.refresh();
    });
  }

  onMount(() => {
    workspaceStore.refresh();
  });

  $effect(() => {
    if (workspaceStore.state === 'open') {
      wireWorkspaceEvents();
    }
  });
</script>

{#if workspaceStore.state === 'loading'}
  <div class="flex min-h-screen items-center justify-center bg-paper-surface"></div>
{:else if workspaceStore.state === 'none'}
  <Onboarding />
{:else}
  {@render children()}
{/if}
