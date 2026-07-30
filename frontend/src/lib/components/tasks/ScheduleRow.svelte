<script lang="ts">
  // One schedule row: title + kind badge on the first line, everything
  // quantitative on one quiet meta line, the disposition's plain-language
  // explanation (with Edit as its recovery) underneath. Expanding loads the
  // run history.
  //
  // Consequence color rules (§2, §4 — the palette does the safety talking):
  //   - the Delete confirm is TERRACOTTA ("green never deletes"; it was the
  //     green primary fill before this pass — the single most quotable
  //     violation in the critique);
  //   - a COMMAND schedule's kind badge is terracotta-tinted, and its Run now
  //     passes an inline confirmation naming the program — it runs with the
  //     user's full authority. A prompt schedule's Run now fires directly: the
  //     session it starts still asks before anything risky.
  //
  // Every decision the row makes comes from `schedule-shapes.ts`, which
  // mirrors the backend's own rules — the button's state and the RPC's answer
  // must never disagree.
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import { humanizeCron } from '$lib/tasks/cadence';
  import type { ScheduleEntry, ScheduleRun } from '$lib/tasks/store.svelte';
  import RunHistory from './RunHistory.svelte';
  import {
    commandLine,
    dispositionLine,
    highlightsAsNew,
    pauseToggle,
    payloadChipLabel,
    payloadChipTone,
    runNowConfirm,
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
    confirmingRun = false,
    onToggleExpand,
    onTogglePause,
    onEdit,
    onRunNow,
    onAskRun,
    onCancelRun,
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
    /** A COMMAND schedule's Run-now confirmation strip is open. */
    confirmingRun?: boolean;
    onToggleExpand: () => void;
    onTogglePause: (next: boolean) => void;
    onEdit: () => void;
    onRunNow: () => void;
    onAskRun: () => void;
    onCancelRun: () => void;
    onAskDelete: () => void;
    onConfirmDelete: () => void;
    onCancelDelete: () => void;
  } = $props();

  const chip = $derived(stateChip(entry));
  const toggle = $derived(pauseToggle(entry));
  const runNowBlocked = $derived(runNowDisabledReason(entry));
  const runConfirm = $derived(runNowConfirm(entry));
  const reason = $derived(dispositionLine(entry));
  const cadence = $derived(entry.cadence === null ? 'no cadence' : humanizeCron(entry.cadence));
  const kindTone = $derived(payloadChipTone(entry.payloadKind));

  function nextFireLabel(iso: string | null): string | null {
    if (iso === null) return null;
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return iso;
    // 24-hour, matching the cadence on the same line ("daily 02:00" beside a
    // 12-hour "07:30 AM" was one row, two clocks).
    return parsed.toLocaleString(undefined, {
      weekday: 'short',
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit',
      hour12: false
    });
  }

  const nextFire = $derived(nextFireLabel(entry.nextFire));

  function runNowClick(): void {
    if (runConfirm === null) {
      onRunNow();
    } else if (!confirmingRun) {
      onAskRun();
    }
  }
</script>

<li class="border-paper-hairline border-b py-2.5 last:border-b-0">
  <div class="flex items-start gap-1.5">
    <button
      type="button"
      aria-expanded={expanded}
      aria-label={expanded ? 'Hide run history' : 'Show run history'}
      onclick={onToggleExpand}
      class="text-ink-meta hover:text-ink-heading flex size-8 shrink-0 items-center justify-center rounded transition-colors"
    >
      <ChevronRight class={['size-4 transition-transform', expanded ? 'rotate-90' : '']} strokeWidth={1.5} />
    </button>

    <div class="min-w-0 flex-1 py-1">
      <div class="flex flex-wrap items-center gap-x-2 gap-y-1">
        <span class="text-ink-heading text-[13.5px] font-semibold">{entry.title ?? entry.id ?? '(untitled)'}</span>
        <!-- §5 kind badge: 10px, 700, uppercase, +0.04em; tint follows
             consequence — a Program badge is terracotta because it runs with
             full authority. -->
        <span
          class={[
            'rounded-full px-1.5 py-0.5 text-[10px] font-bold tracking-[0.04em] uppercase',
            kindTone === 'warn' ? 'bg-warn-tint text-warn-ink' : 'bg-paper-pill text-ink-secondary'
          ]}
        >
          {payloadChipLabel(entry.payloadKind)}
        </span>
        {#if showsAgentBadge(entry)}
          <span
            class="bg-paper-pill text-ink-secondary rounded-full px-1.5 py-0.5 text-[10px] font-bold tracking-[0.04em] uppercase"
          >
            from assistant
          </span>
        {/if}
      </div>

      <div class="mt-0.5 flex flex-wrap items-baseline gap-x-3 gap-y-0.5 text-[11.5px]">
        <span
          class={[
            chip.tone === 'warn' ? 'text-warn-ink' : '',
            chip.tone === 'muted' ? 'text-ink-meta' : '',
            chip.tone === 'ok' ? 'text-act' : ''
          ]}
        >
          {chip.label}
        </span>
        <span class="text-ink-meta">{cadence}</span>
        {#if entry.timezone}
          <span class="text-ink-meta">{entry.timezone}</span>
        {/if}
        {#if nextFire}
          <span class="text-ink-meta tabular-nums">next {nextFire}</span>
        {/if}
        {#if entry.lastOutcome}
          <span class="text-ink-meta">last: {entry.lastOutcome}</span>
        {/if}
        {#if entry.catchup}
          <span class="text-ink-meta">catches up missed runs</span>
        {/if}
        {#if highlightsAsNew(entry)}
          <span class="text-act">new</span>
        {/if}
      </div>

      {#if reason}
        <!-- Per-entry, attributable, repairable — the strict-execution contract's
             visible half, in the user's language, with Edit as the way out. -->
        <p class="text-warn-ink mt-1 text-[12px]">{reason}</p>
      {/if}

      {#if notice}
        <p class="text-ink-meta mt-1 text-[12px]" role="status">{notice}</p>
      {/if}

      {#if expanded}
        <RunHistory {runs} loading={runsLoading} error={runsError} />
      {/if}
    </div>

    <div class="flex shrink-0 items-center gap-1">
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={busy || entry.id === null}
        onclick={onEdit}
      >
        Edit
      </Button>
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
        onclick={runNowClick}
      >
        {runConfirm === null ? 'Run now' : 'Run now…'}
      </Button>
      <button
        type="button"
        aria-label={`Delete ${entry.title ?? entry.id ?? 'schedule'}`}
        disabled={busy || entry.id === null}
        onclick={onAskDelete}
        class="text-ink-meta hover:text-warn-ink flex size-8 items-center justify-center rounded-md transition-colors disabled:opacity-50"
      >
        <Trash2 class="size-3.5" strokeWidth={1.5} />
      </button>
    </div>
  </div>

  {#if runNowBlocked !== null && entry.id !== null}
    <!-- The reason a disabled Run now used to hide in a title= tooltip —
         unreachable by keyboard and touch. Visible text instead. -->
    <p class="text-ink-meta mt-1 ml-9 text-[11.5px]">{runNowBlocked}</p>
  {/if}

  {#if confirmingRun && runConfirm !== null}
    <!-- §4: the consequence is named, the confirm follows, terracotta outline —
         never a filled button, never the default focus. -->
    <div class="border-warn-border bg-paper-card mt-2 ml-9 flex flex-wrap items-center gap-2 rounded-[12px] border p-2.5">
      <p class="text-ink-body flex-1 text-[12.5px]">{runConfirm}</p>
      <Button type="button" variant="ghost" size="sm" onclick={onCancelRun} disabled={busy}>Cancel</Button>
      <Button type="button" variant="destructive" size="sm" onclick={onRunNow} disabled={busy}>
        Run {commandLine(entry.payloadRaw) === null ? 'it' : 'the program'}
      </Button>
    </div>
  {/if}

  {#if confirmingDelete}
    <!-- Inline confirm rather than a modal: the row is the object, and the
         question is one sentence. Terracotta, because deleting is
         irreversible — green never deletes (§2). -->
    <div class="border-warn-border bg-paper-card mt-2 ml-9 flex flex-wrap items-center gap-2 rounded-[12px] border p-2.5">
      <p class="text-ink-body flex-1 text-[12.5px]">
        Delete this schedule? Its run history stays in Valea, but the schedule itself is gone from this project.
      </p>
      <Button type="button" variant="ghost" size="sm" onclick={onCancelDelete} disabled={busy}>Cancel</Button>
      <Button type="button" variant="destructive" size="sm" onclick={onConfirmDelete} disabled={busy}>
        Delete schedule
      </Button>
    </div>
  {/if}
</li>
