import { describe, expect, it } from 'vitest';
import {
  MALFORMED_SCHEDULES_NOTE,
  coalescedLabel,
  dispositionLine,
  durationLabel,
  editOutcomeNotice,
  highlightsAsNew,
  killSwitchCopy,
  outcomeLabel,
  pauseToggle,
  payloadChipLabel,
  runNowDisabledReason,
  runTranscriptHref,
  scheduleErrorMessage,
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
  it('explains only a non-executable entry, using the entry’s own reason', () => {
    expect(dispositionLine(BROKEN)).toBe('Not executable: invalid cron: minute out of range');
    expect(dispositionLine(EXECUTABLE)).toBeNull();
    expect(dispositionLine(PAUSED)).toBeNull();
  });

  it('still says something when the backend sent no reason', () => {
    expect(dispositionLine({ disposition: 'not_executable', reason: null })).toBe(
      'Not executable — it will not fire.'
    );
  });
});

describe('runNowDisabledReason', () => {
  it('allows an executable entry', () => {
    expect(runNowDisabledReason(EXECUTABLE)).toBeNull();
  });

  it('allows a PAUSED entry — an explicit human click overrides a pause once', () => {
    expect(runNowDisabledReason(PAUSED)).toBeNull();
  });

  it('disables a non-executable entry with its displayed reason — no manual bypass', () => {
    expect(runNowDisabledReason(BROKEN)).toBe('Not executable: invalid cron: minute out of range');
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

describe('payloadChipLabel / showsAgentBadge / highlightsAsNew', () => {
  it('labels the two payload kinds and degrades a missing one honestly', () => {
    expect(payloadChipLabel('prompt')).toBe('Prompt');
    expect(payloadChipLabel('command')).toBe('Command');
    expect(payloadChipLabel(null)).toBe('Unknown payload');
    expect(payloadChipLabel('webhook')).toBe('webhook');
  });

  it('badges agent-registered schedules and highlights recent registrations', () => {
    expect(showsAgentBadge(EXECUTABLE)).toBe(true);
    expect(showsAgentBadge(PAUSED)).toBe(false);
    expect(highlightsAsNew(EXECUTABLE)).toBe(true);
    expect(highlightsAsNew(PAUSED)).toBe(false);
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
