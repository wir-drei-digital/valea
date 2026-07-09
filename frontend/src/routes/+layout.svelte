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

  let { children } = $props();

  onMount(() => {
    workspaceStore.refresh();
  });
</script>

{#if workspaceStore.state === 'loading'}
  <div class="flex min-h-screen items-center justify-center bg-paper-surface"></div>
{:else if workspaceStore.state === 'none'}
  <Onboarding />
{:else}
  {@render children()}
{/if}
