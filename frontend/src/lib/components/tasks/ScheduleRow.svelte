<script lang="ts">
  // One schedule row: title, humanized cadence, payload chip, next fire, last
  // outcome, pause toggle, created_by badge, and the entry's disposition reason
  // when it is not executable. Expanding loads the run history.
  //
  // Every decision the row makes (what Run now is allowed on, what the state
  // chip says, whether the highlight applies) comes from `schedule-shapes.ts`,
  // which mirrors the backend's own rules — the button's state and the RPC's
  // answer must never disagree.
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import { humanizeCron } from '$lib/tasks/cadence';
  import type { ScheduleEntry, ScheduleRun } from '$lib/tasks/store.svelte';
  import RunHistory from './RunHistory.svelte';
  import {
    dispositionLine,
    highlightsAsNew,
    pauseToggle,
    payloadChipLabel,
    runNowDisabledReason,
    showsAgentBadge,
    stateChip
  } from './schedule-shapes';

  let {
    entry,
    expanded = false,
    busy = false,
    notice = null,
    runs = [],
    runsLoading = false,
    runsError = null,
    confirmingDelete = false,
    onToggleExpand,
    onTogglePause,
    onRunNow,
    onAskDelete,
    onConfirmDelete,
    onCancelDelete
  }: {
    entry: ScheduleEntry;
    expanded?: boolean;
    busy?: boolean;
    /** Inline line for the freshest write outcome / run-now result — surfaced without waiting for a re-list. */
    notice?: string | null;
    runs?: ScheduleRun[];
    runsLoading?: boolean;
    runsError?: string | null;
    confirmingDelete?: boolean;
    onToggleExpand: () => void;
    onTogglePause: (next: boolean) => void;
    onRunNow: () => void;
    onAskDelete: () => void;
    onConfirmDelete: () => void;
    onCancelDelete: () => void;
  } = $props();

  const chip = $derived(stateChip(entry));
  const toggle = $derived(pauseToggle(entry));
  const runNowBlocked = $derived(runNowDisabledReason(entry));
  const reason = $derived(dispositionLine(entry));
  const cadence = $derived(entry.cadence === null ? 'no cadence' : humanizeCron(entry.cadence));

  function nextFireLabel(iso: string | null): string | null {
    if (iso === null) return null;
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return iso;
    return parsed.toLocaleString(undefined, {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

  const nextFire = $derived(nextFireLabel(entry.nextFire));
</script>

<li
  class={[
    'border-paper-hairline border-b py-2.5 last:border-b-0',
    highlightsAsNew(entry) ? 'border-l-act -ml-2 border-l-2 pl-2' : ''
  ]}
>
  <div class="flex items-start gap-2">
    <button
      type="button"
      aria-expanded={expanded}
      aria-label={expanded ? 'Hide run history' : 'Show run history'}
      onclick={onToggleExpand}
      class="text-ink-meta hover:text-ink-heading mt-0.5 flex size-5 shrink-0 items-center justify-center rounded transition-colors"
    >
      <ChevronRight class={['size-4 transition-transform', expanded ? 'rotate-90' : '']} strokeWidth={1.5} />
    </button>

    <div class="min-w-0 flex-1">
      <div class="flex flex-wrap items-baseline gap-x-2 gap-y-1">
        <span class="text-ink-heading text-[13.5px] font-medium">{entry.title ?? entry.id ?? '(untitled)'}</span>
        <span class="text-ink-body text-[12.5px]">{cadence}</span>
        <span class="bg-paper-pill text-ink-secondary rounded-full px-1.5 py-0.5 text-[10.5px]">
          {payloadChipLabel(entry.payloadKind)}
        </span>
        <span
          class={[
            'text-[11.5px]',
            chip.tone === 'warn' ? 'text-warn-ink' : '',
            chip.tone === 'muted' ? 'text-ink-meta' : '',
            chip.tone === 'ok' ? 'text-act' : ''
          ]}
        >
          {chip.label}
        </span>
        {#if showsAgentBadge(entry)}
          <span class="bg-paper-pill text-ink-secondary rounded-full px-1.5 py-0.5 text-[10.5px]">from agent</span>
        {/if}
        {#if highlightsAsNew(entry)}
          <span class="text-act text-[10.5px]">new</span>
        {/if}
      </div>

      <div class="mt-0.5 flex flex-wrap items-baseline gap-x-3 gap-y-0.5">
        {#if entry.timezone}
          <span class="text-ink-meta text-[11.5px]">{entry.timezone}</span>
        {/if}
        {#if nextFire}
          <span class="text-ink-meta text-[11.5px] tabular-nums">next {nextFire}</span>
        {/if}
        {#if entry.lastOutcome}
          <span class="text-ink-meta text-[11.5px]">last: {entry.lastOutcome}</span>
        {/if}
        {#if entry.catchup}
          <span class="text-ink-meta text-[11.5px]">catch-up on</span>
        {/if}
      </div>

      {#if reason}
        <!-- Per-entry, attributable, repairable — the strict-execution contract's
             visible half. -->
        <p class="text-warn-ink mt-1 text-[12px]">{reason}</p>
      {/if}

      {#if notice}
        <p class="text-ink-meta mt-1 text-[12px]" role="status">{notice}</p>
      {/if}

      {#if expanded}
        <RunHistory {runs} loading={runsLoading} error={runsError} />
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1.5">
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={busy || entry.id === null}
        onclick={() => onTogglePause(toggle.next)}
      >
        {toggle.label}
      </Button>
      <Button
        type="button"
        variant="outline"
        size="sm"
        disabled={busy || runNowBlocked !== null}
        title={runNowBlocked ?? 'Fire this schedule now, out of band'}
        onclick={onRunNow}
      >
        Run now
      </Button>
      <button
        type="button"
        aria-label={`Delete ${entry.title ?? entry.id ?? 'schedule'}`}
        disabled={busy || entry.id === null}
        onclick={onAskDelete}
        class="text-ink-meta hover:text-warn-ink flex size-7 items-center justify-center rounded-md transition-colors disabled:opacity-50"
      >
        <Trash2 class="size-3.5" strokeWidth={1.5} />
      </button>
    </div>
  </div>

  {#if confirmingDelete}
    <!-- Inline confirm rather than a modal: the row is the object, and the
         question is one sentence. -->
    <div class="border-paper-hairline bg-paper-card mt-2 flex flex-wrap items-center gap-2 rounded-[7px] border p-2">
      <p class="text-ink-body flex-1 text-[12.5px]">
        Delete this schedule from schedules.json? Its run history is kept.
      </p>
      <Button type="button" variant="ghost" size="sm" onclick={onCancelDelete} disabled={busy}>Cancel</Button>
      <Button type="button" size="sm" onclick={onConfirmDelete} disabled={busy}>Delete</Button>
    </div>
  {/if}
</li>
