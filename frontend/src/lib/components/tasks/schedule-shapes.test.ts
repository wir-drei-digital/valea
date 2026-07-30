import { describe, expect, it } from 'vitest';
import {
  MALFORMED_SCHEDULES_NOTE,
  coalescedLabel,
  composerTargetAfterSave,
  CADENCE_PRESETS,
  cadenceFromCron,
  commandLine,
  cronFromCadence,
  dispositionLine,
  durationLabel,
  editOutcomeNotice,
  highlightsAsNew,
  killSwitchCopy,
  outcomeLabel,
  pauseToggle,
  payloadChipLabel,
  payloadChipTone,
  runNowConfirm,
  runNowDisabledReason,
  runTranscriptHref,
  scheduleErrorMessage,
  scheduleRowKey,
  schedulesLedgerNote,
  showsAgentBadge,
  stateChip,
  triggerLabel
} from './schedule-shapes';
import { normalizeSchedule, normalizeScheduleRun } from '$lib/tasks/store.svelte';

// The wire shape `list_schedules` delivers: `schedules` is an unconstrained
// `{:array, :map}`, so entry keys arrive as `Valea.Api.Schedules`'
// `schedule_payload/4` builds them — snake_case (`payload_kind`, `next_fire`,
// `registered_recently`).
const EXECUTABLE = normalizeSchedule({
  id: 's-morning-brief',
  title: 'Morning inbox brief',
  disposition: 'executable',
  reason: null,
  cadence: '30 7 * * 1-5',
  timezone: 'Europe/Zurich',
  payload_kind: 'prompt',
  paused: false,
  catchup: false,
  created_by: 'agent',
  next_fire: '2026-07-31T05:30:00Z',
  last_outcome: 'ok',
  registered_recently: true
});

const PAUSED = normalizeSchedule({
  id: 's-paused',
  title: 'Weekly sync',
  disposition: 'paused',
  reason: null,
  cadence: '0 9 * * 1',
  payload_kind: 'command',
  paused: true,
  created_by: 'user',
  next_fire: null,
  last_outcome: 'failed',
  registered_recently: false
});

const BROKEN = normalizeSchedule({
  id: 's-broken',
  title: 'Nightly sync',
  disposition: 'not_executable',
  reason: 'invalid cron: minute out of range',
  cadence: '30 25 * * *',
  payload_kind: 'command',
  paused: false,
  created_by: 'agent',
  next_fire: null,
  last_outcome: null,
  registered_recently: false
});

const ID_LESS = normalizeSchedule({
  title: 'Nameless',
  disposition: 'not_executable',
  reason: 'missing id',
  cadence: '0 9 * * *'
});

describe('schedulesLedgerNote', () => {
  it('says an unreadable file fires NOTHING, and stays silent otherwise', () => {
    expect(schedulesLedgerNote('unreadable')).toContain(MALFORMED_SCHEDULES_NOTE);
    expect(schedulesLedgerNote('unreadable')).toContain('Nothing fires');
    expect(schedulesLedgerNote('absent')).toBeNull();
    expect(schedulesLedgerNote('ok')).toBeNull();
  });
});

describe('the tri-state kill switch', () => {
  it('off: no banner, toggleable', () => {
    expect(killSwitchCopy('off')).toMatchObject({ engaged: false, toggleable: true, banner: null, tone: 'none' });
  });

  it('on: a deliberate pause, with the "never back-fires" promise spelled out', () => {
    const copy = killSwitchCopy('on');
    expect(copy.engaged).toBe(true);
    expect(copy.toggleable).toBe(true);
    expect(copy.tone).toBe('notice');
    expect(copy.banner).toContain('All schedules are paused');
    expect(copy.banner).toContain('skipped for good');
  });

  it('unreadable: a CONFIG problem — never "you paused this", and not toggleable', () => {
    const copy = killSwitchCopy('unreadable');
    expect(copy.engaged).toBe(true);
    expect(copy.tone).toBe('warn');
    expect(copy.banner).toContain('Scheduling paused: workspace config unreadable');
    expect(copy.banner).toContain('config/workspace.yaml');
    // The whole point of the third state: it must not claim the user did it.
    expect(copy.banner).not.toMatch(/you paused/i);
    // Valea refuses to rewrite a config it cannot read, so the switch is inert.
    expect(copy.toggleable).toBe(false);
  });
});

describe('dispositionLine', () => {
  it('translates an invalid cron into plain language, quoting the raw expression, ending in the recovery', () => {
    expect(dispositionLine(BROKEN)).toBe(
      'Valea can’t read “30 25 * * *” as a schedule. Edit it and pick a day and time.'
    );
    expect(dispositionLine(EXECUTABLE)).toBeNull();
    expect(dispositionLine(PAUSED)).toBeNull();
  });

  it('never leaks the validator’s vocabulary', () => {
    expect(dispositionLine(BROKEN)).not.toContain('Not executable');
    expect(dispositionLine(BROKEN)).not.toContain('invalid cron');
  });

  it('handles an invalid cron with no raw expression to quote', () => {
    expect(dispositionLine({ disposition: 'not_executable', reason: 'invalid cron: expected 5 fields', cadence: null })).toBe(
      'Valea can’t read this schedule’s timing. Edit it and pick a day and time.'
    );
  });

  it('explains a duplicate id with its own recovery', () => {
    expect(
      dispositionLine({ disposition: 'not_executable', reason: 'duplicate id', cadence: '0 9 * * *' })
    ).toContain('Two schedules share this id');
  });

  it('explains an unknown timezone and names the empty-means-this-computer default', () => {
    expect(
      dispositionLine({ disposition: 'not_executable', reason: 'unknown timezone', cadence: '0 9 * * *' })
    ).toContain('timezone');
  });

  it('still says something when the backend sent no reason', () => {
    expect(dispositionLine({ disposition: 'not_executable', reason: null, cadence: null })).toBe(
      'This schedule won’t fire. Edit it to fix what’s missing.'
    );
  });

  it('carries an unrecognized reason verbatim rather than hiding it', () => {
    expect(
      dispositionLine({ disposition: 'not_executable', reason: 'context_doc escapes the ICM', cadence: '0 9 * * *' })
    ).toBe('This schedule won’t fire — context_doc escapes the ICM. Edit it to fix that.');
  });
});

describe('runNowDisabledReason', () => {
  it('allows an executable entry', () => {
    expect(runNowDisabledReason(EXECUTABLE)).toBeNull();
  });

  it('allows a PAUSED entry — an explicit human click overrides a pause once', () => {
    expect(runNowDisabledReason(PAUSED)).toBeNull();
  });

  it('disables a non-executable entry, pointing at the row’s own explanation — no manual bypass', () => {
    expect(runNowDisabledReason(BROKEN)).toBe('This schedule can’t run until it’s fixed — see the note on its row.');
  });

  it('disables an entry Valea cannot address at all', () => {
    expect(runNowDisabledReason(ID_LESS)).toContain('no id');
  });
});

describe('pauseToggle', () => {
  it('offers Pause for a running entry and Resume for a paused one, with the value the click writes', () => {
    expect(pauseToggle(EXECUTABLE)).toEqual({ label: 'Pause', next: true });
    expect(pauseToggle(PAUSED)).toEqual({ label: 'Resume', next: false });
  });
});

describe('stateChip', () => {
  it('reports Active / Paused / Not executable, with non-executable winning', () => {
    expect(stateChip(EXECUTABLE)).toEqual({ label: 'Active', tone: 'ok' });
    expect(stateChip(PAUSED)).toEqual({ label: 'Paused', tone: 'muted' });
    expect(stateChip(BROKEN)).toEqual({ label: 'Not executable', tone: 'warn' });
    // A malformed pause attempt must NEVER read as a running schedule.
    expect(stateChip({ disposition: 'not_executable', paused: true })).toEqual({
      label: 'Not executable',
      tone: 'warn'
    });
  });
});

describe('payloadChipLabel / payloadChipTone / showsAgentBadge / highlightsAsNew', () => {
  it('labels the two payload kinds in the user’s language and degrades a missing one honestly', () => {
    expect(payloadChipLabel('prompt')).toBe('Chat task');
    expect(payloadChipLabel('command')).toBe('Program');
    expect(payloadChipLabel(null)).toBe('Unknown');
    expect(payloadChipLabel('webhook')).toBe('webhook');
  });

  it('tints only the command badge terracotta — the one kind that runs with full authority', () => {
    expect(payloadChipTone('command')).toBe('warn');
    expect(payloadChipTone('prompt')).toBe('neutral');
    expect(payloadChipTone(null)).toBe('neutral');
  });

  it('badges agent-registered schedules and highlights recent registrations', () => {
    expect(showsAgentBadge(EXECUTABLE)).toBe(true);
    expect(showsAgentBadge(PAUSED)).toBe(false);
    expect(highlightsAsNew(EXECUTABLE)).toBe(true);
    expect(highlightsAsNew(PAUSED)).toBe(false);
  });
});

describe('runNowConfirm / commandLine', () => {
  it('demands a confirmation naming the program for a COMMAND schedule', () => {
    const entry = normalizeSchedule({
      id: 's-backup',
      disposition: 'executable',
      payload_kind: 'command',
      payload: { kind: 'command', command: './scripts/backup.sh', args: ['--quiet'] }
    });
    expect(runNowConfirm(entry)).toBe(
      'Run ./scripts/backup.sh --quiet now? It runs with your full access to this project’s folder.'
    );
  });

  it('asks generically when the command itself is unreadable', () => {
    expect(runNowConfirm({ payloadKind: 'command', payloadRaw: null })).toBe(
      'Run this program now? It runs with your full access to this project’s folder.'
    );
  });

  it('needs NO confirmation for a prompt schedule — its session still asks before anything risky', () => {
    expect(runNowConfirm(EXECUTABLE)).toBeNull();
  });

  it('renders the command line from the raw payload, dropping non-string args', () => {
    expect(commandLine({ command: 'python3', args: ['sync.py', 7, '--dry'] })).toBe('python3 sync.py --dry');
    expect(commandLine({ command: '   ' })).toBeNull();
    expect(commandLine(null)).toBeNull();
  });
});

describe('cadence presets', () => {
  it('writes the four preset shapes', () => {
    expect(cronFromCadence('weekdays', '07:30', '1')).toBe('30 7 * * 1-5');
    expect(cronFromCadence('daily', '02:00', '1')).toBe('0 2 * * *');
    expect(cronFromCadence('weekly', '09:00', '5')).toBe('0 9 * * 5');
    expect(cronFromCadence('monthly', '08:15', '1')).toBe('15 8 1 * *');
  });

  it('refuses rather than guesses: custom, bad time, bad weekday', () => {
    expect(cronFromCadence('custom', '09:00', '1')).toBeNull();
    expect(cronFromCadence('daily', '25:00', '1')).toBeNull();
    expect(cronFromCadence('daily', 'morning', '1')).toBeNull();
    expect(cronFromCadence('weekly', '09:00', '9')).toBeNull();
  });

  it('round-trips every preset it writes', () => {
    for (const [preset, time, weekday] of [
      ['weekdays', '07:30', '1'],
      ['daily', '02:00', '1'],
      ['weekly', '09:00', '5'],
      ['monthly', '08:15', '1']
    ] as const) {
      const cron = cronFromCadence(preset, time, weekday);
      expect(cron).not.toBeNull();
      const back = cadenceFromCron(cron!);
      expect(back).not.toBeNull();
      expect(back!.preset).toBe(preset);
      expect(back!.time).toBe(time);
      if (preset === 'weekly') expect(back!.weekday).toBe(weekday);
    }
  });

  it('answers null — Custom — for any cron it would not have written', () => {
    expect(cadenceFromCron('*/15 * * * *')).toBeNull();
    expect(cadenceFromCron('0 9 13 * 5')).toBeNull();
    expect(cadenceFromCron('0 9 2 * *')).toBeNull();
    expect(cadenceFromCron('@daily')).toBeNull();
    expect(cadenceFromCron('not a cron')).toBeNull();
  });
});

describe('run-history row formatting', () => {
  const promptRun = normalizeScheduleRun({
    id: 'r-1',
    slot: '2026-07-30T05:30:00Z',
    fired_at: '2026-07-30T05:30:01Z',
    trigger: 'scheduled',
    kind: 'prompt',
    outcome: 'ok',
    duration_ms: 1234,
    session_id: 'sess-9',
    output: null,
    coalesced_count: 1
  });

  const skipRun = normalizeScheduleRun({
    id: 'r-2',
    fired_at: '2026-07-30T06:30:00Z',
    trigger: 'scheduled',
    kind: 'command',
    outcome: 'skipped: still running',
    duration_ms: null,
    session_id: null,
    output: 'stdout tail',
    coalesced_count: 3
  });

  it('formats durations across the ms / s / m boundaries', () => {
    expect(durationLabel(340)).toBe('340 ms');
    expect(durationLabel(1234)).toBe('1.2 s');
    expect(durationLabel(59_999)).toBe('60.0 s');
    expect(durationLabel(185_000)).toBe('3 m 05 s');
    expect(durationLabel(null)).toBeNull();
    expect(durationLabel(-1)).toBeNull();
  });

  it('shows a coalesced count only when it stands for more than one slot', () => {
    expect(coalescedLabel(3)).toBe('coalesced ×3');
    expect(coalescedLabel(1)).toBeNull();
    expect(coalescedLabel(null)).toBeNull();
  });

  it('links a prompt run’s transcript and never a command run’s', () => {
    expect(runTranscriptHref(promptRun)).toBe('/chat?session=sess-9');
    expect(runTranscriptHref(skipRun)).toBeNull();
  });

  it('labels triggers and outcomes, with a running row reading as running', () => {
    expect(triggerLabel('scheduled')).toBe('scheduled');
    expect(triggerLabel('manual')).toBe('run now');
    expect(triggerLabel('catchup')).toBe('catch-up');
    expect(triggerLabel(null)).toBe('unknown trigger');
    expect(outcomeLabel(promptRun)).toBe('ok');
    expect(outcomeLabel(skipRun)).toBe('skipped: still running');
    expect(outcomeLabel({ outcome: null })).toBe('running');
  });

  it('keeps a command run’s captured output for the <pre> block', () => {
    expect(skipRun.output).toBe('stdout tail');
    expect(promptRun.output).toBeNull();
  });
});

describe('editOutcomeNotice', () => {
  it('surfaces a not-executable verdict from the write’s OWN reply, no re-list needed', () => {
    expect(editOutcomeNotice({ disposition: 'not_executable', reason: 'invalid cron' })).toBe(
      'Saved — but it will not fire: invalid cron'
    );
    expect(editOutcomeNotice({ disposition: 'not_executable', reason: null })).toBe(
      'Saved — but it will not fire: not executable.'
    );
  });

  it('says a paused entry will not fire, and stays quiet for a healthy one', () => {
    expect(editOutcomeNotice({ disposition: 'paused', reason: null })).toContain('paused');
    expect(editOutcomeNotice({ disposition: 'executable', reason: null })).toBeNull();
    // A vanished entry answers null/null — nothing honest to say about it.
    expect(editOutcomeNotice({ disposition: null, reason: null })).toBeNull();
  });
});

// Review round 1, L7: every bit of the tab's per-row state (expanded, busy,
// notice, run history, delete confirmation) hangs off this key.
describe('scheduleRowKey', () => {
  it('addresses a row by its id, scoped to the ICM — two ICMs may hold the same id', () => {
    expect(scheduleRowKey('primary', 's-1', 0)).toBe('primary/s-1');
    expect(scheduleRowKey('primary', 's-1', 0)).not.toBe(scheduleRowKey('clients', 's-1', 0));
    // The index never enters the key of an addressable row: re-ordering the
    // file must not drop the expansion the user opened.
    expect(scheduleRowKey('primary', 's-1', 4)).toBe(scheduleRowKey('primary', 's-1', 0));
  });

  it('keeps two id-less entries in one ICM apart — they used to share one key, and one expansion', () => {
    expect(scheduleRowKey('primary', null, 0)).not.toBe(scheduleRowKey('primary', null, 1));
    // …and neither can collide with a real id (`Valea.Schedules` trims ids and
    // none of them contains a `#`).
    expect(scheduleRowKey('primary', null, 0)).toBe('primary/#0');
  });
});

// Review round 1, L4: a create that LANDS but reads back non-executable leaves
// the composer open on its notice. Every create stamps a fresh id, so the next
// Save has to mutate what was just written rather than write a twin.
describe('composerTargetAfterSave', () => {
  it('adopts the id a landed create handed back', () => {
    expect(composerTargetAfterSave(null, { id: 's-9' })).toBe('s-9');
  });

  it('keeps the entry it is already editing — a mutate answers with no id of its own', () => {
    expect(composerTargetAfterSave('s-9', {})).toBe('s-9');
    expect(composerTargetAfterSave('s-9', { id: 's-other' })).toBe('s-9');
  });

  it('stays in create mode when there is no usable id, rather than addressing a blank', () => {
    expect(composerTargetAfterSave(null, {})).toBeNull();
    expect(composerTargetAfterSave(null, { id: null })).toBeNull();
    expect(composerTargetAfterSave(null, { id: '   ' })).toBeNull();
  });
});

describe('scheduleErrorMessage', () => {
  it('maps every code `Valea.Api.Schedules.error_for/1` can produce', () => {
    const codes = [
      'not_executable',
      'duplicate_id',
      'not_found',
      'already_running',
      'scheduler_paused',
      'workspace_changed',
      'workspace_not_open',
      'icm_unavailable',
      'conflict',
      'unreadable',
      'config_unreadable',
      'internal_error'
    ];
    for (const code of codes) {
      expect(scheduleErrorMessage(code)).not.toBe('That didn’t work. Please try again.');
    }
    expect(scheduleErrorMessage('some_new_atom')).toBe('That didn’t work. Please try again.');
  });
});
