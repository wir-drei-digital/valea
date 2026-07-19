<script lang="ts">
  // The sidebar-bottom update notice (release/auto-update spec 2026-07-19)
  // — the only renderer of `updatesStore.phase`. Amber "suggest" family:
  // an available update is the app suggesting; restarting is the act
  // (green). Hidden entirely while there is nothing to say — idle and
  // checking render nothing, so the browser build and an up-to-date app
  // never show a card.
  import { updatesStore } from '$lib/stores/updates.svelte';

  const phase = $derived(updatesStore.phase);
  const percent = $derived(
    phase.kind === 'downloading' && phase.total !== null && phase.total > 0
      ? Math.min(100, Math.round((phase.downloaded / phase.total) * 100))
      : null
  );
</script>

{#if phase.kind !== 'idle' && phase.kind !== 'checking'}
  <div
    role="status"
    aria-live="polite"
    class="rounded-lg border border-suggest-border bg-suggest-bg px-2.5 py-2 text-[12px] leading-snug"
  >
    {#if phase.kind === 'downloading'}
      <p class="text-ink-secondary">Downloading Valea v{phase.version}…</p>
      <div class="mt-1.5 h-1 overflow-hidden rounded-full bg-paper-track">
        <!-- Unknown content length → indeterminate: a pulsing partial bar. -->
        <div
          class="h-full rounded-full bg-act-dot transition-[width] duration-300"
          class:animate-pulse={percent === null}
          style:width={percent === null ? '40%' : `${percent}%`}
        ></div>
      </div>
    {:else if phase.kind === 'ready' || phase.kind === 'installing'}
      <p class="text-ink-secondary">Valea v{phase.version} is ready to install.</p>
      <button
        type="button"
        class="mt-1.5 w-full rounded-md bg-act px-2 py-1 font-medium text-paper-card transition-colors hover:bg-act-hover disabled:opacity-60"
        disabled={phase.kind === 'installing'}
        onclick={() => void updatesStore.installAndRelaunch()}
      >
        {phase.kind === 'installing' ? 'Restarting…' : 'Restart to update'}
      </button>
    {:else if phase.kind === 'error'}
      <p class="text-ink-secondary">{phase.message}</p>
      {#if phase.retriable}
        <button
          type="button"
          class="mt-1 font-medium text-suggest-ink underline-offset-2 hover:underline"
          onclick={() => updatesStore.retry()}
        >
          Try again
        </button>
      {/if}
    {/if}
  </div>
{/if}
