<script lang="ts">
  // The Schedules tab: every enabled ICM's registry, the tri-state Pause-all
  // header, and per-row pause / run-now / delete plus expandable run history.
  //
  // The honest limitation is stated on the page, not buried: nothing fires while
  // Valea is closed (spec §Decisions — "Limitation stated honestly in the UI").
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { EmptyState } from '$lib/components/shell';
  import { mountProvenanceLabel } from '$lib/shell/provenance';
  import CalendarClock from '@lucide/svelte/icons/calendar-clock';
  import { tasksStore, type ScheduleRun } from '$lib/tasks/store.svelte';
  import { humanizeCron } from '$lib/tasks/cadence';
  import ScheduleRow from './ScheduleRow.svelte';
  import {
    composerTargetAfterSave,
    editOutcomeNotice,
    killSwitchCopy,
    scheduleErrorMessage,
    scheduleRowKey,
    schedulesLedgerNote
  } from './schedule-shapes';

  const icms = $derived(tasksStore.scheduleIcms);
  const killSwitch = $derived(killSwitchCopy(tasksStore.schedulerPaused));

  // The row key (`scheduleRowKey`, tested) is computed ONCE per row in the
  // markup below and handed to every handler, rather than each handler
  // recomputing it — it now depends on the row's index too, which the handlers
  // have no business knowing.
  let expanded = $state<Record<string, boolean>>({});
  let runs = $state<Record<string, ScheduleRun[]>>({});
  let runsLoading = $state<Record<string, boolean>>({});
  let runsError = $state<Record<string, string | null>>({});
  let notices = $state<Record<string, string | null>>({});
  let busyRow = $state<string | null>(null);
  let confirmingDelete = $state<string | null>(null);
  let pauseAllBusy = $state(false);
  let pauseAllError = $state<string | null>(null);

  async function toggleExpand(key: string, mountKey: string, scheduleId: string | null): Promise<void> {
    const next = !expanded[key];
    expanded = { ...expanded, [key]: next };
    if (!next || scheduleId === null) return;
    await loadRuns(key, mountKey, scheduleId);
  }

  async function loadRuns(key: string, mountKey: string, scheduleId: string): Promise<void> {
    runsLoading = { ...runsLoading, [key]: true };
    runsError = { ...runsError, [key]: null };
    const result = await tasksStore.runHistory(mountKey, scheduleId);
    runsLoading = { ...runsLoading, [key]: false };
    if (result.ok) {
      runs = { ...runs, [key]: result.runs };
    } else {
      runsError = { ...runsError, [key]: scheduleErrorMessage(result.error) };
    }
  }

  /**
   * A pause toggle answers with the entry's freshly read-back disposition, so
   * "saved, and it will not fire: `paused` is not a boolean" lands on the row
   * immediately — no waiting for the watcher-driven re-list.
   */
  async function togglePause(
    key: string,
    mountKey: string,
    scheduleId: string | null,
    next: boolean
  ): Promise<void> {
    if (scheduleId === null) return;
    busyRow = key;
    try {
      const outcome = await tasksStore.setSchedulePaused(mountKey, scheduleId, next);
      notices = {
        ...notices,
        [key]: outcome.ok ? editOutcomeNotice(outcome) : scheduleErrorMessage(outcome.error)
      };
    } finally {
      busyRow = null;
    }
  }

  async function runNow(key: string, mountKey: string, scheduleId: string | null): Promise<void> {
    if (scheduleId === null) return;
    busyRow = key;
    try {
      const outcome = await tasksStore.runNow(mountKey, scheduleId);
      notices = {
        ...notices,
        [key]: outcome.ok ? 'Fired now — this run does not shift the schedule.' : scheduleErrorMessage(outcome.error)
      };
      if (outcome.ok && expanded[key]) await loadRuns(key, mountKey, scheduleId);
    } finally {
      busyRow = null;
    }
  }

  async function confirmDelete(key: string, mountKey: string, scheduleId: string | null): Promise<void> {
    if (scheduleId === null) return;
    busyRow = key;
    try {
      const outcome = await tasksStore.deleteSchedule(mountKey, scheduleId);
      if (outcome.ok) {
        confirmingDelete = null;
      } else {
        notices = { ...notices, [key]: scheduleErrorMessage(outcome.error) };
      }
    } finally {
      busyRow = null;
    }
  }

  async function togglePauseAll(): Promise<void> {
    if (!killSwitch.toggleable) return;
    pauseAllBusy = true;
    pauseAllError = null;
    try {
      const outcome = await tasksStore.setSchedulerPaused(!killSwitch.engaged);
      if (!outcome.ok) pauseAllError = scheduleErrorMessage(outcome.error);
    } finally {
      pauseAllBusy = false;
    }
  }

  // -- composer ---------------------------------------------------------------

  let composerOpen = $state(false);
  let composerMountKey = $state('');
  let composerTitle = $state('');
  let composerCron = $state('0 9 * * 1-5');
  let composerTimezone = $state('');
  let composerKind = $state<'prompt' | 'command'>('prompt');
  let composerPrompt = $state('');
  let composerContextDoc = $state('');
  let composerCommand = $state('');
  let composerArgs = $state('');
  let composerBusy = $state(false);
  let composerNotice = $state<string | null>(null);
  let composerError = $state<string | null>(null);
  /**
   * Set once a create has LANDED (review round 1, L4). The composer stays open
   * after a lenient write that came back non-executable, and every
   * `create_schedule` stamps a fresh id — so from that moment on, Save must
   * MUTATE the entry it just wrote rather than write a twin. `null` = the
   * composer has not created anything yet.
   */
  let composerEditingId = $state<string | null>(null);

  $effect(() => {
    const keys = icms.map((icm) => icm.mountKey);
    if (keys.length > 0 && !keys.includes(composerMountKey)) composerMountKey = keys[0];
  });

  const composerCadence = $derived(composerCron.trim() === '' ? null : humanizeCron(composerCron.trim()));

  /** The file's own field names, verbatim — `create_schedule`'s `fields` is unconstrained on purpose. */
  function composerFields(): Record<string, unknown> {
    const payload: Record<string, unknown> =
      composerKind === 'prompt'
        ? {
            kind: 'prompt',
            prompt: composerPrompt,
            ...(composerContextDoc.trim() === '' ? {} : { context_doc: composerContextDoc.trim() })
          }
        : {
            kind: 'command',
            command: composerCommand.trim(),
            // Exec-style spawn: an args ARRAY, never a shell string.
            args: composerArgs
              .split('\n')
              .map((arg) => arg.trim())
              .filter((arg) => arg !== '')
          };

    return {
      title: composerTitle.trim(),
      cron: composerCron.trim(),
      ...(composerTimezone.trim() === '' ? {} : { timezone: composerTimezone.trim() }),
      payload,
      paused: false
    };
  }

  /**
   * Back to a blank composer — also the "Cancel" path. It clears the per-entry
   * text (title, prompt, command, args, context doc) and the save notices, so
   * nothing entry-specific leaks into the next one. `cron`, `timezone` and
   * `kind` deliberately survive: they are the shape the user just picked, and
   * `cron` starts from a working default rather than empty.
   */
  function closeComposer(): void {
    composerOpen = false;
    composerEditingId = null;
    composerTitle = '';
    composerPrompt = '';
    composerCommand = '';
    composerArgs = '';
    composerContextDoc = '';
    composerNotice = null;
    composerError = null;
  }

  async function saveComposer(): Promise<void> {
    composerBusy = true;
    composerNotice = null;
    composerError = null;
    try {
      // The write is LENIENT either way — an invalid entry lands and shows up
      // non-executable — so the composer reports the verdict it just got back
      // rather than pretending the save was clean, and stays open on it.
      if (composerEditingId === null) {
        const outcome = await tasksStore.createSchedule(composerMountKey, composerFields());
        if (!outcome.ok) {
          composerError = scheduleErrorMessage(outcome.error);
          return;
        }
        // The create LANDED, flagged or not — re-point the composer at the
        // entry it just wrote, so a second Save fixes that one instead of
        // writing a twin (L4).
        composerEditingId = composerTargetAfterSave(null, outcome);
        composerNotice = editOutcomeNotice(outcome);
      } else {
        const outcome = await tasksStore.patchSchedule(composerMountKey, composerEditingId, composerFields());
        if (!outcome.ok) {
          composerError = scheduleErrorMessage(outcome.error);
          return;
        }
        composerNotice = editOutcomeNotice(outcome);
      }

      if (composerNotice === null) closeComposer();
    } finally {
      composerBusy = false;
    }
  }

  const canSave = $derived(
    composerMountKey !== '' &&
      composerTitle.trim() !== '' &&
      composerCron.trim() !== '' &&
      (composerKind === 'prompt' ? composerPrompt.trim() !== '' : composerCommand.trim() !== '') &&
      !composerBusy
  );
</script>

{#if icms.length === 0}
  <EmptyState
    icon={CalendarClock}
    title="No projects yet"
    body="Schedules live in a schedules.json file at the root of each project. Mount or create a project first and the registry appears here."
  />
{:else}
  <div class="flex flex-col gap-4">
    <div class="border-paper-hairline flex flex-wrap items-center justify-between gap-3 rounded-[9px] border p-3">
      <div class="min-w-0">
        <p class="text-ink-heading text-[13px] font-semibold">{killSwitch.label}</p>
        <p class="text-ink-meta mt-0.5 text-[12px]">
          Schedules fire only while Valea is running — nothing happens while the app is closed.
        </p>
      </div>
      <Button
        type="button"
        variant="outline"
        size="sm"
        role="switch"
        aria-checked={killSwitch.engaged}
        disabled={pauseAllBusy || !killSwitch.toggleable}
        onclick={() => void togglePauseAll()}
      >
        {killSwitch.engaged ? 'Resume all' : 'Pause all'}
      </Button>
    </div>

    {#if killSwitch.banner}
      <p
        class={['text-[12.5px]', killSwitch.tone === 'warn' ? 'text-warn-ink' : 'text-ink-body']}
        role={killSwitch.tone === 'warn' ? 'alert' : 'status'}
      >
        {killSwitch.banner}
      </p>
    {/if}

    {#if pauseAllError}
      <p class="text-warn-ink text-[12.5px]" role="alert">{pauseAllError}</p>
    {/if}

    <div>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onclick={() => (composerOpen ? closeComposer() : (composerOpen = true))}
      >
        {#if !composerOpen}
          New schedule
        {:else if composerEditingId === null}
          Cancel new schedule
        {:else}
          Done editing
        {/if}
      </Button>
    </div>

    {#if composerOpen}
      <div class="border-paper-hairline flex flex-col gap-3 rounded-[9px] border p-3">
        {#if icms.length > 1}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-icm">Project</Label>
            <!-- Locked once the entry exists: it lives in THAT project's
                 schedules.json, and a later Save patches it there. -->
            <select
              id="sched-new-icm"
              class="border-paper-hairline bg-paper-surface text-ink-body rounded-[7px] border px-2 py-1.5 text-[12.5px]"
              bind:value={composerMountKey}
              disabled={composerBusy || composerEditingId !== null}
            >
              {#each icms as icm (icm.mountKey)}
                <option value={icm.mountKey}>{icm.icmName || icm.mountKey}</option>
              {/each}
            </select>
          </div>
        {/if}

        <div class="flex flex-col gap-1">
          <Label for="sched-new-title">Title</Label>
          <Input id="sched-new-title" type="text" bind:value={composerTitle} disabled={composerBusy} />
        </div>

        <div class="flex flex-wrap gap-3">
          <div class="flex flex-1 flex-col gap-1">
            <Label for="sched-new-cron">Cadence (cron)</Label>
            <Input id="sched-new-cron" type="text" bind:value={composerCron} disabled={composerBusy} />
            {#if composerCadence}
              <p class="text-ink-meta text-[11.5px]">{composerCadence}</p>
            {/if}
          </div>
          <div class="flex flex-col gap-1">
            <Label for="sched-new-tz">Timezone (optional)</Label>
            <Input
              id="sched-new-tz"
              type="text"
              placeholder="host zone"
              bind:value={composerTimezone}
              disabled={composerBusy}
            />
          </div>
        </div>

        <div class="flex flex-col gap-1">
          <Label for="sched-new-kind">Payload</Label>
          <select
            id="sched-new-kind"
            class="border-paper-hairline bg-paper-surface text-ink-body rounded-[7px] border px-2 py-1.5 text-[12.5px]"
            bind:value={composerKind}
            disabled={composerBusy}
          >
            <option value="prompt">Prompt (starts an agent session)</option>
            <option value="command">Command (runs a program)</option>
          </select>
        </div>

        {#if composerKind === 'prompt'}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-prompt">Prompt</Label>
            <textarea
              id="sched-new-prompt"
              class="border-paper-hairline bg-paper-surface text-ink-body min-h-16 rounded-[7px] border px-2 py-1.5 text-[12.5px]"
              bind:value={composerPrompt}
              disabled={composerBusy}
            ></textarea>
          </div>
          <div class="flex flex-col gap-1">
            <Label for="sched-new-context">Context doc (optional, project-relative)</Label>
            <Input
              id="sched-new-context"
              type="text"
              placeholder="communications/workflows/inbox-triage.md"
              bind:value={composerContextDoc}
              disabled={composerBusy}
            />
          </div>
        {:else}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-command">Command</Label>
            <Input
              id="sched-new-command"
              type="text"
              placeholder="python3"
              bind:value={composerCommand}
              disabled={composerBusy}
            />
          </div>
          <div class="flex flex-col gap-1">
            <Label for="sched-new-args">Arguments (one per line)</Label>
            <textarea
              id="sched-new-args"
              class="border-paper-hairline bg-paper-surface text-ink-body min-h-16 rounded-[7px] border px-2 py-1.5 font-mono text-[11.5px]"
              bind:value={composerArgs}
              disabled={composerBusy}
            ></textarea>
            <p class="text-ink-meta text-[11.5px]">
              Run with your full authority in the project folder — there is no sandbox, and no shell (arguments are
              passed through as written).
            </p>
          </div>
        {/if}

        {#if composerNotice}
          <p class="text-warn-ink text-[12px]" role="status">{composerNotice}</p>
        {/if}
        {#if composerError}
          <p class="text-warn-ink text-[12px]" role="alert">{composerError}</p>
        {/if}

        <div class="flex items-center justify-end gap-3">
          {#if composerEditingId !== null}
            <!-- The entry is on disk already (it is in the list below, flagged).
                 Saying so is what makes the second Save legible as a fix. -->
            <p class="text-ink-meta text-[11.5px]">Already saved — Save updates it.</p>
          {/if}
          <Button type="button" size="sm" disabled={!canSave} onclick={() => void saveComposer()}>
            {composerEditingId === null ? 'Save schedule' : 'Save changes'}
          </Button>
        </div>
      </div>
    {/if}

    <div class="flex flex-col gap-7">
      {#each icms as icm (icm.mountKey)}
        {@const note = schedulesLedgerNote(icm.status)}
        <section>
          <span class="text-ink-meta text-[12px]">
            {mountProvenanceLabel(icm.icmName) ?? `· ${icm.mountKey}`}
          </span>

          {#if note}
            <p class="text-ink-meta mt-1.5 text-[12.5px]">{note}</p>
          {/if}

          {#if icm.schedules.length === 0}
            {#if icm.status !== 'unreadable'}
              <p class="text-ink-meta mt-1.5 text-[12.5px]">No schedules here.</p>
            {/if}
          {:else}
            <ul class="mt-1.5 flex flex-col">
              {#each icm.schedules as entry, index (entry.id ?? `no-id-${index}`)}
                {@const key = scheduleRowKey(icm.mountKey, entry.id, index)}
                <ScheduleRow
                  {entry}
                  expanded={expanded[key] === true}
                  busy={busyRow === key}
                  notice={notices[key] ?? null}
                  runs={runs[key] ?? []}
                  runsLoading={runsLoading[key] === true}
                  runsError={runsError[key] ?? null}
                  confirmingDelete={confirmingDelete === key}
                  onToggleExpand={() => void toggleExpand(key, icm.mountKey, entry.id)}
                  onTogglePause={(next) => void togglePause(key, icm.mountKey, entry.id, next)}
                  onRunNow={() => void runNow(key, icm.mountKey, entry.id)}
                  onAskDelete={() => (confirmingDelete = key)}
                  onConfirmDelete={() => void confirmDelete(key, icm.mountKey, entry.id)}
                  onCancelDelete={() => (confirmingDelete = null)}
                />
              {/each}
            </ul>
          {/if}
        </section>
      {/each}
    </div>
  </div>
{/if}
