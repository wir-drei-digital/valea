<script lang="ts">
  // A schedule's run history (spec §UI surfaces: fired_at, outcome, duration,
  // trigger, coalesced count; prompt runs link their transcript, command runs
  // show captured output inline).
  //
  // History is keyed `(icm_id, schedule_id)` backend-side, so it survives the
  // schedule's deletion and a mount rename — this is the PRIMARY access path to
  // a scheduled session, since the session lists hide them by default.
  import type { ScheduleRun } from '$lib/tasks/store.svelte';
  import { coalescedLabel, durationLabel, outcomeLabel, runTranscriptHref, triggerLabel } from './schedule-shapes';

  let {
    runs,
    loading = false,
    error = null
  }: {
    runs: ScheduleRun[];
    loading?: boolean;
    error?: string | null;
  } = $props();

  function firedAtLabel(iso: string | null): string {
    if (iso === null) return 'unknown time';
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return iso;
    return parsed.toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }
</script>

<div class="border-paper-hairline mt-2 border-t pt-2">
  {#if error}
    <p class="text-warn-ink text-[12px]" role="alert">{error}</p>
  {:else if loading}
    <p class="text-ink-meta text-[12px]">Loading runs…</p>
  {:else if runs.length === 0}
    <p class="text-ink-meta text-[12px]">
      No runs recorded yet. Schedules fire only while Valea is running.
    </p>
  {:else}
    <ul class="flex flex-col gap-2">
      {#each runs as run, index (run.id ?? `run-${index}`)}
        {@const href = runTranscriptHref(run)}
        {@const duration = durationLabel(run.durationMs)}
        {@const coalesced = coalescedLabel(run.coalescedCount)}
        <li class="flex flex-col gap-1">
          <div class="flex flex-wrap items-baseline gap-x-2 gap-y-0.5">
            <span class="text-ink-body text-[12.5px] tabular-nums">{firedAtLabel(run.firedAt)}</span>
            <span class="text-ink-heading text-[12.5px]">{outcomeLabel(run)}</span>
            <span class="text-ink-meta text-[11.5px]">{triggerLabel(run.trigger)}</span>
            {#if duration}
              <span class="text-ink-meta text-[11.5px] tabular-nums">{duration}</span>
            {/if}
            {#if coalesced}
              <span class="text-ink-meta text-[11.5px]">{coalesced}</span>
            {/if}
            {#if href}
              <a {href} class="text-ink-secondary hover:text-ink-heading text-[11.5px] hover:underline">
                Open transcript
              </a>
            {/if}
          </div>
          {#if run.output}
            <!-- Already capped at 256 KiB by the writer; the pre scrolls rather
                 than stretching the row. -->
            <pre
              class="bg-paper-track text-ink-body max-h-48 overflow-auto rounded-[6px] px-2 py-1.5 font-mono text-[11.5px] whitespace-pre-wrap">{run.output}</pre>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>
