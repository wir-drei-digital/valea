/**
 * Render decisions for the Schedules tab (`SchedulesTab.svelte` /
 * `ScheduleRow.svelte` / `RunHistory.svelte`) — the pure half, so the copy that
 * has to be exactly right is pinned by tests.
 *
 * Two of those are load-bearing:
 *
 *   1. **The kill switch is TRI-state.** `"unreadable"` means
 *      `config/workspace.yaml` will not parse, so nobody can say what the user
 *      asked for. It fails CLOSED, and its copy must read as a CONFIG PROBLEM —
 *      never "you paused this" (`Valea.Api.Schedules`' moduledoc: folding it
 *      into `true` would tell the user they paused something they did not).
 *   2. **Run now has no manual bypass.** It is allowed for `executable` AND
 *      `paused` entries (an explicit human click overrides a pause once) and
 *      refused for `not_executable`/duplicate ones with the entry's OWN
 *      displayed reason.
 */
import type { Disposition, ScheduleEntry, ScheduleRun, SchedulerPause } from '$lib/tasks/store.svelte';

export const MALFORMED_SCHEDULES_NOTE = 'unreadable — fix by hand or ask the agent';

/**
 * The per-ICM note under the provenance header. An unreadable
 * `schedules.json` is fail-safe: NOTHING fires from a file Valea cannot parse,
 * and the note says so — an absent file is just an ICM with no schedules.
 */
export function schedulesLedgerNote(status: 'ok' | 'absent' | 'unreadable'): string | null {
  return status === 'unreadable' ? `schedules.json is ${MALFORMED_SCHEDULES_NOTE}. Nothing fires from it.` : null;
}

/** Copy for the header Pause-all control. `banner` is `null` when there is nothing to announce. */
export type KillSwitchCopy = {
  /** The switch's own label. */
  label: string;
  /** `true` when the switch reads as engaged (both `on` and `unreadable` — the latter fails closed). */
  engaged: boolean;
  /** Whether the user can toggle it — an unreadable config must be fixed by hand first. */
  toggleable: boolean;
  banner: string | null;
  tone: 'none' | 'notice' | 'warn';
};

export function killSwitchCopy(state: SchedulerPause): KillSwitchCopy {
  switch (state) {
    case 'on':
      return {
        label: 'Pause all schedules',
        engaged: true,
        toggleable: true,
        banner: 'All schedules are paused. Nothing fires until you resume — slots that pass meanwhile are skipped for good.',
        tone: 'notice'
      };
    case 'unreadable':
      return {
        label: 'Pause all schedules',
        engaged: true,
        toggleable: false,
        // NOT "you paused this": nobody knows what the user asked for, so the
        // copy names the config, and Valea refuses to rewrite a file it cannot
        // read (the toggle stays disabled).
        banner: 'Scheduling paused: workspace config unreadable. Fix config/workspace.yaml by hand — nothing fires until it parses.',
        tone: 'warn'
      };
    default:
      return { label: 'Pause all schedules', engaged: false, toggleable: true, banner: null, tone: 'none' };
  }
}

/**
 * The disposition line under a row — only a non-executable entry has something
 * to explain, and it explains in the user's language, not the validator's
 * ("Not executable: invalid cron: expected 5 fields, got 3" named the fault in
 * parser dialect and offered no way out — critique P-issue). Every line ends
 * with the recovery, because the row now HAS one: Edit.
 */
export function dispositionLine(
  entry: Pick<ScheduleEntry, 'disposition' | 'reason' | 'cadence'>
): string | null {
  if (entry.disposition !== 'not_executable') return null;
  const reason = entry.reason ?? '';
  if (reason.startsWith('invalid cron')) {
    return entry.cadence === null
      ? 'Valea can’t read this schedule’s timing. Edit it and pick a day and time.'
      : `Valea can’t read “${entry.cadence}” as a schedule. Edit it and pick a day and time.`;
  }
  if (reason.startsWith('unknown timezone')) {
    return 'Valea doesn’t know this schedule’s timezone. Edit it — leaving the timezone empty uses this computer’s.';
  }
  if (reason === 'duplicate id') {
    return 'Two schedules share this id, so neither one fires. Edit one of them to use a different id.';
  }
  if (reason === '') return 'This schedule won’t fire. Edit it to fix what’s missing.';
  return `This schedule won’t fire — ${reason}. Edit it to fix that.`;
}

/**
 * Why Run now is disabled, or `null` when it is allowed. Mirrors the backend's
 * own rule so the button's state and the RPC's answer never disagree.
 */
export function runNowDisabledReason(entry: Pick<ScheduleEntry, 'disposition' | 'reason' | 'id'>): string | null {
  if (entry.id === null) return 'This entry has no id, so Valea can’t address it.';
  if (entry.disposition !== 'not_executable') return null;
  return 'This schedule can’t run until it’s fixed — see the note on its row.';
}

/**
 * The inline confirmation a Run-now click must pass for a COMMAND schedule —
 * it starts a program with the user's full authority, so §4's rule applies (the
 * label names the consequence, a confirmation always follows). `null` for a
 * prompt schedule: the session it starts still asks before anything risky, so
 * an extra gate here would be ceremony.
 */
export function runNowConfirm(
  entry: Pick<ScheduleEntry, 'payloadKind' | 'payloadRaw'>
): string | null {
  if (entry.payloadKind !== 'command') return null;
  const line = commandLine(entry.payloadRaw);
  return line === null
    ? 'Run this program now? It runs with your full access to this project’s folder.'
    : `Run ${line} now? It runs with your full access to this project’s folder.`;
}

/** `"./backup.sh --quiet"` from the raw payload, or `null` when there is none to show. */
export function commandLine(payloadRaw: Record<string, unknown> | null): string | null {
  if (payloadRaw === null || typeof payloadRaw.command !== 'string' || payloadRaw.command.trim() === '') return null;
  const args = Array.isArray(payloadRaw.args)
    ? payloadRaw.args.filter((arg): arg is string => typeof arg === 'string')
    : [];
  return [payloadRaw.command, ...args].join(' ');
}

/** The pause toggle's label and the value a click writes — `paused` is a FILE field, so this is a real edit. */
export function pauseToggle(entry: Pick<ScheduleEntry, 'paused'>): { label: string; next: boolean } {
  return entry.paused ? { label: 'Resume', next: false } : { label: 'Pause', next: true };
}

export function payloadChipLabel(kind: string | null): string {
  switch (kind) {
    case 'prompt':
      return 'Chat task';
    case 'command':
      return 'Program';
    case null:
      return 'Unknown';
    default:
      return kind;
  }
}

/**
 * §5 tint-follows-consequence for the kind badge: a `command` runs on the
 * user's machine with full authority — terracotta territory, and the one place
 * on the row the palette must do the safety talking. Everything else is
 * informational neutral.
 */
export function payloadChipTone(kind: string | null): 'warn' | 'neutral' {
  return kind === 'command' ? 'warn' : 'neutral';
}

// -- cadence presets ----------------------------------------------------------
//
// The composer's default is a DAY + TIME question ("Every weekday at 07:30"),
// with raw cron one toggle away — §1's "technical detail is one toggle away,
// never the default", applied literally (critique P-issue: the composer opened
// on a cron expression).

export type CadencePreset = 'weekdays' | 'daily' | 'weekly' | 'monthly' | 'custom';

export const CADENCE_PRESETS: { value: CadencePreset; label: string }[] = [
  { value: 'weekdays', label: 'Every weekday' },
  { value: 'daily', label: 'Every day' },
  { value: 'weekly', label: 'Every week' },
  { value: 'monthly', label: 'Monthly, on the 1st' },
  { value: 'custom', label: 'Custom (cron)' }
];

export const WEEKDAY_OPTIONS: { value: string; label: string }[] = [
  { value: '1', label: 'Monday' },
  { value: '2', label: 'Tuesday' },
  { value: '3', label: 'Wednesday' },
  { value: '4', label: 'Thursday' },
  { value: '5', label: 'Friday' },
  { value: '6', label: 'Saturday' },
  { value: '0', label: 'Sunday' }
];

/**
 * The cron a preset + `HH:MM` time (+ weekday for `weekly`) writes. `null` for
 * `custom` (the raw field owns it) or an unparseable time — the composer treats
 * `null` as "not saveable yet", never guesses.
 */
export function cronFromCadence(preset: CadencePreset, time: string, weekday: string): string | null {
  if (preset === 'custom') return null;
  const match = /^(\d{1,2}):(\d{2})$/.exec(time.trim());
  if (match === null) return null;
  const hours = Number(match[1]);
  const minutes = Number(match[2]);
  if (hours > 23 || minutes > 59) return null;
  switch (preset) {
    case 'weekdays':
      return `${minutes} ${hours} * * 1-5`;
    case 'daily':
      return `${minutes} ${hours} * * *`;
    case 'weekly':
      return /^[0-6]$/.test(weekday) ? `${minutes} ${hours} * * ${weekday}` : null;
    case 'monthly':
      return `${minutes} ${hours} 1 * *`;
  }
}

/**
 * The reverse map, for seeding the composer from an existing entry: a cron
 * matching one of the preset shapes exactly comes back as that preset; anything
 * else — including every expression this module wouldn't have written — is
 * `null`, and the composer opens on Custom with the raw string shown. Honest
 * both ways: presets never mis-describe a cron they can't round-trip.
 */
export function cadenceFromCron(
  cron: string
): { preset: Exclude<CadencePreset, 'custom'>; time: string; weekday: string } | null {
  const match = /^(\d{1,2}) (\d{1,2}) (\*|1) \* (\*|1-5|[0-6])$/.exec(cron.trim());
  if (match === null) return null;
  const minutes = Number(match[1]);
  const hours = Number(match[2]);
  if (hours > 23 || minutes > 59) return null;
  const time = `${String(hours).padStart(2, '0')}:${String(minutes).padStart(2, '0')}`;
  const [, , , dom, dow] = match;
  if (dom === '1' && dow === '*') return { preset: 'monthly', time, weekday: '1' };
  if (dom !== '*') return null;
  if (dow === '1-5') return { preset: 'weekdays', time, weekday: '1' };
  if (dow === '*') return { preset: 'daily', time, weekday: '1' };
  return { preset: 'weekly', time, weekday: dow };
}

/** `created_by: "agent"` earns the badge — an agent registered this schedule. */
export function showsAgentBadge(entry: Pick<ScheduleEntry, 'createdBy'>): boolean {
  return entry.createdBy === 'agent';
}

/** The spec's subtle highlight for a schedule registered or changed inside the last 24 h. */
export function highlightsAsNew(entry: Pick<ScheduleEntry, 'registeredRecently'>): boolean {
  return entry.registeredRecently;
}

/**
 * The row's state chip: pause beats disposition in the wording, because a
 * paused entry that is ALSO invalid still needs its reason on the line below
 * (`dispositionLine`), and "Paused" is what the toggle says.
 */
export function stateChip(entry: Pick<ScheduleEntry, 'disposition' | 'paused'>): {
  label: string;
  tone: 'ok' | 'muted' | 'warn';
} {
  if (entry.disposition === 'not_executable') return { label: 'Not executable', tone: 'warn' };
  if (entry.paused || entry.disposition === 'paused') return { label: 'Paused', tone: 'muted' };
  return { label: 'Active', tone: 'ok' };
}

/** `"1.2 s"` / `"340 ms"` / `"3 m 05 s"`, or `null` when the run recorded no duration (a skip record does not). */
export function durationLabel(ms: number | null): string | null {
  if (ms === null || ms < 0) return null;
  if (ms < 1000) return `${ms} ms`;
  if (ms < 60_000) return `${(ms / 1000).toFixed(1)} s`;
  const minutes = Math.floor(ms / 60_000);
  const seconds = Math.floor((ms % 60_000) / 1000);
  return `${minutes} m ${String(seconds).padStart(2, '0')} s`;
}

/** "coalesced ×3" for a skip record that stands for several elapsed slots; `null` for a plain single run. */
export function coalescedLabel(count: number | null): string | null {
  return count !== null && count > 1 ? `coalesced ×${count}` : null;
}

/** A prompt run's transcript link; `null` for a command run (its output is shown inline instead). */
export function runTranscriptHref(run: Pick<ScheduleRun, 'sessionId'>): string | null {
  return run.sessionId === null || run.sessionId === '' ? null : `/chat?session=${encodeURIComponent(run.sessionId)}`;
}

export function triggerLabel(trigger: string | null): string {
  switch (trigger) {
    case 'scheduled':
      return 'scheduled';
    case 'manual':
      return 'run now';
    case 'catchup':
      return 'catch-up';
    case null:
      return 'unknown trigger';
    default:
      return trigger;
  }
}

/** The outcome as shown, with `null` (a still-running row) reading as "running". */
export function outcomeLabel(run: Pick<ScheduleRun, 'outcome'>): string {
  return run.outcome === null || run.outcome === '' ? 'running' : run.outcome;
}

/**
 * `Valea.Api.Schedules.error_for/1`'s whole vocabulary, one calm sentence each.
 * `not_executable`, `duplicate_id` and `scheduler_paused` are the three Run-now
 * refusals; the rest are shared with every other workspace RPC.
 */
export function scheduleErrorMessage(code: string): string {
  switch (code) {
    case 'not_executable':
      return 'This schedule isn’t executable — fix the reason on its row first.';
    case 'duplicate_id':
      return 'Two schedules share this id, so neither one runs. Give one of them a different id.';
    case 'not_found':
      return 'That schedule is no longer in the file.';
    case 'already_running':
      return 'This schedule is already running. One run at a time.';
    case 'scheduler_paused':
      return 'All schedules are paused. Resume them to run this.';
    case 'workspace_changed':
      return 'The workspace changed while you were editing. Reload and try again.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'icm_unavailable':
      return 'That project isn’t available right now.';
    case 'conflict':
      return 'Something else wrote the file at the same time. Nothing was written — try again.';
    case 'unreadable':
      return `schedules.json is ${MALFORMED_SCHEDULES_NOTE}. Nothing fires from it.`;
    case 'config_unreadable':
      return 'config/workspace.yaml doesn’t parse, so Valea won’t rewrite it. Fix it by hand.';
    case 'internal_error':
      return 'Valea couldn’t complete that. Please try again.';
    default:
      return 'That didn’t work. Please try again.';
  }
}

/**
 * What a create/mutate reply should say inline, straight off the response's own
 * `disposition`/`reason` — surfaced WITHOUT waiting for a re-list, so a composer
 * that just saved `"30 25 * * *"` hears about it immediately. `null` when the
 * entry is fine (nothing worth a line).
 */
export function editOutcomeNotice(outcome: {
  disposition: string | null;
  reason: string | null;
}): string | null {
  if (outcome.disposition === null) return null;
  if (outcome.disposition === 'not_executable') {
    return outcome.reason === null
      ? 'Saved — but it will not fire: not executable.'
      : `Saved — but it will not fire: ${outcome.reason}`;
  }
  if (outcome.disposition === 'paused') return 'Saved. This schedule is paused, so it will not fire.';
  return null;
}

/** Narrowing helper for the tab's own use — keeps the union name in one place. */
export function isExecutable(disposition: Disposition): boolean {
  return disposition === 'executable';
}

/**
 * The per-row key every bit of the tab's local state hangs off (expanded, busy,
 * notices, run history, delete confirmation).
 *
 * An entry with no `id` is not addressable, but it is still a ROW, and two of
 * them in the same ICM must not share state (review round 1, L7 — they used to
 * collapse onto `"<mount>/"`, so expanding one expanded the other). Its file
 * position is the only thing that distinguishes it, so that is what the key
 * uses; `#` cannot collide with a real id, which `Valea.Schedules` trims and
 * never lets contain one.
 */
export function scheduleRowKey(mountKey: string, scheduleId: string | null, index: number): string {
  return `${mountKey}/${scheduleId ?? `#${index}`}`;
}

/**
 * Which entry the composer's NEXT save must target, after a save came back ok.
 *
 * A create is LENIENT: an invalid entry still lands, and the composer stays
 * open showing "saved — but it will not fire: …" so the user can correct it.
 * Every `create_schedule` stamps a FRESH id, so pressing Save again in that
 * state used to write a SECOND entry (review round 1, L4). Taking the created
 * id here switches the composer to mutating what it just wrote; once set, it
 * stays set (a composer already editing an entry keeps editing that one).
 */
export function composerTargetAfterSave(current: string | null, outcome: { id?: string | null }): string | null {
  if (current !== null) return current;
  return typeof outcome.id === 'string' && outcome.id.trim() !== '' ? outcome.id : null;
}
