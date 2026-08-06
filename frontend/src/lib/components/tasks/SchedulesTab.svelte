<script lang="ts">
  // The Schedules tab: the composer first, then every enabled ICM's registry
  // with per-row pause / edit / run-now / delete plus expandable run history,
  // and the tri-state Pause-all switch last, as a quiet footer — making a
  // schedule is the reason to open this tab; pausing every one of them is the
  // rare thing, and it has nothing to say until there IS a schedule.
  //
  // The honest limitation is stated on the page, not buried: nothing fires while
  // Valea is closed (spec §Decisions — "Limitation stated honestly in the UI").
  //
  // The composer asks WHAT first and WHEN second, and "when" is a day-and-time
  // question by default — raw cron sits behind the "Custom (cron)" preset,
  // which is §1's "technical detail is one toggle away" applied literally
  // (critique P-issue: the composer opened on a cron expression, and a broken
  // schedule could not be edited at all).
  import { tick } from 'svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { NativeSelect } from '$lib/components/ui/native-select/index.js';
  import { EmptyState } from '$lib/components/shell';
  import CalendarClock from '@lucide/svelte/icons/calendar-clock';
  import { tasksStore, type ScheduleEntry, type ScheduleRun } from '$lib/tasks/store.svelte';
  import { humanizeCron } from '$lib/tasks/cadence';
  import ScheduleRow from './ScheduleRow.svelte';
  import {
    CADENCE_PRESETS,
    WEEKDAY_OPTIONS,
    cadenceFromCron,
    composerTargetAfterSave,
    cronFromCadence,
    editOutcomeNotice,
    killSwitchCopy,
    scheduleErrorMessage,
    scheduleRowKey,
    schedulesLedgerNote,
    type CadencePreset
  } from './schedule-shapes';

  const icms = $derived(tasksStore.scheduleIcms);
  const killSwitch = $derived(killSwitchCopy(tasksStore.schedulerPaused));

  /**
   * The sections that earn a heading: one holding rows, or one whose ledger has
   * something to say for itself (`schedulesLedgerNote` — an unreadable
   * `schedules.json` is NOT an empty one, and must keep saying so). An empty,
   * readable section collapses entirely; the composer above it is the answer.
   */
  const listedIcms = $derived(
    icms.filter((icm) => icm.schedules.length > 0 || schedulesLedgerNote(icm.status) !== null)
  );

  /**
   * One line, once, instead of the same sentence under every project heading.
   *
   * It renders exactly when NO section does, which is also the only state in
   * which it is true: an unreadable ledger keeps its section, so "no schedules
   * yet" is never said over a file Valea could not read (that would dress a
   * read failure up as a fact about the user's files — the one thing the
   * leniency contract must never do).
   */
  const showsEmptyLine = $derived(listedIcms.length === 0);

  /** Nothing anywhere to pause means the kill switch has nothing to offer — the footer stays away. */
  const anySchedules = $derived(icms.some((icm) => icm.schedules.length > 0));

  // The row key (`scheduleRowKey`, tested) is computed ONCE per row in the
  // markup below and handed to every handler, rather than each handler
  // recomputing it — it depends on the row's index too, which the handlers
  // have no business knowing.
  let expanded = $state<Record<string, boolean>>({});
  let runs = $state<Record<string, ScheduleRun[]>>({});
  let runsLoading = $state<Record<string, boolean>>({});
  let runsError = $state<Record<string, string | null>>({});
  let notices = $state<Record<string, string | null>>({});
  let busyRow = $state<string | null>(null);
  let confirmingDelete = $state<string | null>(null);
  /** The row whose COMMAND Run-now is awaiting its inline confirmation (prompt runs need none — their session still asks). */
  let confirmingRun = $state<string | null>(null);
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
      if (outcome.ok) confirmingRun = null;
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

  let composerEl = $state<HTMLElement | null>(null);
  let composerOpen = $state(false);
  let composerMountKey = $state('');
  let composerTitle = $state('');
  let composerPreset = $state<CadencePreset>('weekdays');
  let composerTime = $state('09:00');
  let composerWeekday = $state('1');
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
   * Set once a create has LANDED (review round 1, L4) or a row's Edit opened
   * the composer. From that moment on, Save MUTATES that entry rather than
   * writing a twin. `null` = the composer has not created anything yet.
   */
  let composerEditingId = $state<string | null>(null);

  $effect(() => {
    const keys = icms.map((icm) => icm.mountKey);
    if (keys.length > 0 && !keys.includes(composerMountKey)) composerMountKey = keys[0];
  });

  /** The cron a save writes: the preset's, or the raw field's on Custom. `null` = not saveable yet. */
  const effectiveCron = $derived(
    composerPreset === 'custom'
      ? composerCron.trim() === ''
        ? null
        : composerCron.trim()
      : cronFromCadence(composerPreset, composerTime, composerWeekday)
  );

  const composerCadence = $derived(effectiveCron === null ? null : humanizeCron(effectiveCron));

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
      cron: effectiveCron ?? '',
      ...(composerTimezone.trim() === '' ? {} : { timezone: composerTimezone.trim() }),
      payload,
      paused: false
    };
  }

  /**
   * Back to a blank composer — also the "Close" path. It clears the per-entry
   * text (title, prompt, command, args, context doc) and the save notices, so
   * nothing entry-specific leaks into the next one. The cadence controls
   * (`composerPreset`/`composerTime`/`composerWeekday`/`composerCron`), `kind`
   * and the target ICM (`composerMountKey`) deliberately survive: they are the
   * shape and destination the user just picked, and the cadence starts from a
   * working default rather than empty.
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

  /**
   * A row's Edit: seed the composer from the entry and point Save at it. The
   * cadence seeds as a preset when the cron round-trips through
   * `cadenceFromCron`, and as Custom (raw string shown) when it doesn't —
   * presets never mis-describe a cron they can't reproduce.
   */
  async function editEntry(mountKey: string, entry: ScheduleEntry): Promise<void> {
    if (entry.id === null) return;
    composerOpen = true;
    composerEditingId = entry.id;
    composerMountKey = mountKey;
    composerTitle = entry.title ?? '';
    composerTimezone = entry.timezone ?? '';
    composerNotice = null;
    composerError = null;

    const cadence = entry.cadence === null ? null : cadenceFromCron(entry.cadence);
    if (cadence === null) {
      composerPreset = 'custom';
      composerCron = entry.cadence ?? '';
    } else {
      composerPreset = cadence.preset;
      composerTime = cadence.time;
      composerWeekday = cadence.weekday;
    }

    const payload = entry.payloadRaw ?? {};
    composerKind = entry.payloadKind === 'command' ? 'command' : 'prompt';
    composerPrompt = typeof payload.prompt === 'string' ? payload.prompt : '';
    composerContextDoc = typeof payload.context_doc === 'string' ? payload.context_doc : '';
    composerCommand = typeof payload.command === 'string' ? payload.command : '';
    composerArgs = Array.isArray(payload.args)
      ? payload.args.filter((arg): arg is string => typeof arg === 'string').join('\n')
      : '';

    await tick();
    composerEl?.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
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
      effectiveCron !== null &&
      (composerKind === 'prompt' ? composerPrompt.trim() !== '' : composerCommand.trim() !== '') &&
      !composerBusy
  );
</script>

{#if icms.length === 0}
  <EmptyState
    icon={CalendarClock}
    title="No projects yet"
    body="Each project keeps its own schedule of recurring work, in a plain file you can always open yourself. Add a project from the sidebar and the schedules appear here."
  />
{:else}
  <div class="flex flex-col gap-4">
    <div>
      <Button
        type="button"
        variant="outline"
        size="sm"
        onclick={() => (composerOpen ? closeComposer() : (composerOpen = true))}
      >
        {composerOpen ? 'Close' : 'New schedule'}
      </Button>
    </div>

    {#if composerOpen}
      <!-- The system's card, not a third box style: §6 anatomy, card border,
           radius 12, card paper. -->
      <div
        bind:this={composerEl}
        class="border-paper-border bg-paper-card shadow-card flex flex-col gap-3 rounded-[12px] border p-4"
      >
        {#if icms.length > 1}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-icm">Project</Label>
            <!-- Locked once the entry exists: it lives in THAT project's
                 schedule file, and a later Save patches it there. -->
            <NativeSelect
              id="sched-new-icm"
              bind:value={composerMountKey}
              disabled={composerBusy || composerEditingId !== null}
            >
              {#each icms as icm (icm.mountKey)}
                <option value={icm.mountKey}>{icm.icmName || icm.mountKey}</option>
              {/each}
            </NativeSelect>
          </div>
        {/if}

        <div class="flex flex-col gap-1">
          <Label for="sched-new-title">Title</Label>
          <Input id="sched-new-title" type="text" bind:value={composerTitle} disabled={composerBusy} />
        </div>

        <div class="flex flex-col gap-1">
          <Label for="sched-new-kind">What it does</Label>
          <NativeSelect id="sched-new-kind" bind:value={composerKind} disabled={composerBusy}>
            <option value="prompt">Chat task — the assistant works on it</option>
            <option value="command">Program — runs on this computer</option>
          </NativeSelect>
        </div>

        {#if composerKind === 'prompt'}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-prompt">What should it do?</Label>
            <textarea
              id="sched-new-prompt"
              class="border-input focus-visible:border-ring focus-visible:ring-ring/50 text-ink-body min-h-16 rounded-lg border bg-transparent px-2.5 py-1.5 text-sm transition-colors outline-none focus-visible:ring-3 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50"
              placeholder="Go through the inbox and add anything that needs my attention to the task list."
              bind:value={composerPrompt}
              disabled={composerBusy}
            ></textarea>
            <p class="text-ink-meta text-[11.5px]">
              The assistant still asks before doing anything risky, same as in a chat you start yourself.
            </p>
          </div>
          <div class="flex flex-col gap-1">
            <Label for="sched-new-context">Give it a page to read first (optional)</Label>
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
            <Label for="sched-new-command">Program</Label>
            <Input
              id="sched-new-command"
              type="text"
              placeholder="./scripts/backup.sh"
              bind:value={composerCommand}
              disabled={composerBusy}
            />
            <p class="text-ink-meta text-[11.5px]">
              A path in this project's folder (write <span class="font-mono">./name</span> for a script here) or a
              program on this computer.
            </p>
          </div>
          <div class="flex flex-col gap-1">
            <Label for="sched-new-args">Arguments (one per line)</Label>
            <textarea
              id="sched-new-args"
              class="border-input focus-visible:border-ring focus-visible:ring-ring/50 text-ink-body min-h-16 rounded-lg border bg-transparent px-2.5 py-1.5 font-mono text-[11.5px] transition-colors outline-none focus-visible:ring-3 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50"
              bind:value={composerArgs}
              disabled={composerBusy}
            ></textarea>
            <!-- Terracotta, not meta-grey: this is the most consequential
                 sentence on the form (critique: it was the smallest, lightest
                 text on the page). -->
            <p class="text-warn-ink text-[12px]">
              It runs with your full access to this folder — no sandbox, and it does not ask first.
            </p>
          </div>
        {/if}

        <div class="flex flex-wrap items-end gap-3">
          <div class="flex flex-col gap-1">
            <Label for="sched-new-preset">When</Label>
            <NativeSelect id="sched-new-preset" bind:value={composerPreset} disabled={composerBusy}>
              {#each CADENCE_PRESETS as preset (preset.value)}
                <option value={preset.value}>{preset.label}</option>
              {/each}
            </NativeSelect>
          </div>
          {#if composerPreset === 'weekly'}
            <div class="flex flex-col gap-1">
              <Label for="sched-new-weekday">On</Label>
              <NativeSelect id="sched-new-weekday" bind:value={composerWeekday} disabled={composerBusy}>
                {#each WEEKDAY_OPTIONS as day (day.value)}
                  <option value={day.value}>{day.label}</option>
                {/each}
              </NativeSelect>
            </div>
          {/if}
          {#if composerPreset !== 'custom'}
            <div class="flex flex-col gap-1">
              <Label for="sched-new-time">At</Label>
              <Input id="sched-new-time" type="time" bind:value={composerTime} disabled={composerBusy} class="w-auto" />
            </div>
          {:else}
            <div class="flex min-w-[180px] flex-1 flex-col gap-1">
              <Label for="sched-new-cron">Cron expression</Label>
              <Input id="sched-new-cron" type="text" bind:value={composerCron} disabled={composerBusy} />
            </div>
          {/if}
          <div class="flex flex-col gap-1">
            <Label for="sched-new-tz">Timezone (optional)</Label>
            <Input
              id="sched-new-tz"
              type="text"
              placeholder="this computer's"
              bind:value={composerTimezone}
              disabled={composerBusy}
            />
          </div>
        </div>
        {#if composerCadence}
          <p class="text-ink-meta text-[11.5px]">{composerCadence}</p>
        {/if}

        {#if composerNotice}
          <p class="text-warn-ink text-[12px]" role="status">{composerNotice}</p>
        {/if}
        {#if composerError}
          <p class="text-warn-ink text-[12px]" role="alert">{composerError}</p>
        {/if}

        <div class="flex items-center justify-end gap-3">
          {#if composerEditingId !== null}
            <!-- The entry is on disk already (it is in the list below).
                 Saying so is what makes Save legible as a fix. -->
            <p class="text-ink-meta text-[11.5px]">Already saved — Save updates it.</p>
          {/if}
          <Button type="button" size="sm" disabled={!canSave} onclick={() => void saveComposer()}>
            {composerEditingId === null ? 'Save schedule' : 'Save changes'}
          </Button>
        </div>
      </div>
    {/if}

    {#if showsEmptyLine}
      <p class="text-ink-meta text-[12.5px]">No schedules here yet.</p>
    {/if}

    {#if listedIcms.length > 0}
      <div class="flex flex-col gap-7">
        {#each listedIcms as icm (icm.mountKey)}
          {@const note = schedulesLedgerNote(icm.status)}
          <section>
            <h2 class="text-overline">{icm.icmName || icm.mountKey}</h2>

            {#if note}
              <p class="text-ink-meta mt-1.5 text-[12.5px]">{note}</p>
            {/if}

            {#if icm.schedules.length > 0}
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
                    confirmingRun={confirmingRun === key}
                    onToggleExpand={() => void toggleExpand(key, icm.mountKey, entry.id)}
                    onTogglePause={(next) => void togglePause(key, icm.mountKey, entry.id, next)}
                    onEdit={() => void editEntry(icm.mountKey, entry)}
                    onRunNow={() => void runNow(key, icm.mountKey, entry.id)}
                    onAskRun={() => (confirmingRun = key)}
                    onCancelRun={() => (confirmingRun = null)}
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
    {/if}

    {#if anySchedules}
      <!-- Unboxed (§11: never boxed section headers) — the kill switch is a
           quiet footer row, separated by the same hairline the lists use. Its
           banner and error ride along with it: they announce what the switch
           did, and an announcement with no switch in sight is a headless one. -->
      <footer class="border-paper-hairline mt-6 border-t pt-4">
        <p class="text-overline">Schedules pause</p>
        <div class="mt-1.5 flex flex-wrap items-center justify-between gap-3">
          <p class="text-ink-meta min-w-0 text-[12px]">
            Schedules fire only while Valea is running — nothing happens while the app is closed.
          </p>
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
            class={['mt-2 text-[12.5px]', killSwitch.tone === 'warn' ? 'text-warn-ink' : 'text-ink-body']}
            role={killSwitch.tone === 'warn' ? 'alert' : 'status'}
          >
            {killSwitch.banner}
          </p>
        {/if}

        {#if pauseAllError}
          <p class="text-warn-ink mt-2 text-[12.5px]" role="alert">{pauseAllError}</p>
        {/if}
      </footer>
    {/if}
  </div>
{/if}
