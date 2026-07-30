import { describe, expect, it } from 'vitest';
import { mailSummaryLine, normalizeCockpitToday } from './cockpit';

// Mirrors the Spec-D cockpit payload shape from `backend/lib/valea/cockpit.ex`
// — an unconstrained-looking but fully typed :map, so keys arrive snake_case
// (see `Valea.Api.Cockpit`'s moduledoc for why the nested arrays still
// camelCase like every other typed action).
const rawSnake = {
  sections: [
    {
      mount_key: 'primary',
      icm_name: 'Mara Lindt Coaching',
      ok: true,
      updated_at: '2026-07-16T08:00:00Z',
      notes: 'Quiet day.',
      prepared: [{ title: 'Prep Lea', summary: 'One page', page: 'clients/lea.md' }],
      // The tasks line REPLACED `open_loops` (tasks+schedules spec §Cockpit).
      // A nested plain `:map` keeps its SOURCE keys on the wire even though the
      // emitted TS types camelCase them — pinned by
      // `test/valea_web/rpc_test.exs`, normalized either way here.
      tasks: {
        due_today: 2,
        overdue: 1,
        in_progress: 1,
        top: [{ id: 't-1', title: 'Send proposal', due: '2026-07-16', today: true, priority: 'high' }]
      }
    }
  ],
  mail: [{ account: 'work', configured: true, state: 'idle', pendingOps: 2, notices: ['held folder'] }],
  recent_sessions: [
    { id: 'sess-1', title: 'Chat with Lea', started_at: '2026-07-16T08:00:00Z', status: 'ended', live: false }
  ]
};

describe('normalizeCockpitToday', () => {
  it('maps snake_case payload keys into the typed camelCase shape', () => {
    const today = normalizeCockpitToday(rawSnake);

    expect(today.sections).toHaveLength(1);
    const [section] = today.sections;
    expect(section.mountKey).toBe('primary');
    expect(section.icmName).toBe('Mara Lindt Coaching');
    expect(section.ok).toBe(true);
    expect(section.updatedAt).toBe('2026-07-16T08:00:00Z');
    expect(section.notes).toBe('Quiet day.');
    expect(section.prepared).toEqual([{ title: 'Prep Lea', summary: 'One page', page: 'clients/lea.md' }]);
    expect(section.tasks).toEqual({
      dueToday: 2,
      overdue: 1,
      inProgress: 1,
      top: [{ id: 't-1', title: 'Send proposal', due: '2026-07-16', today: true, priority: 'high' }]
    });

    expect(today.mail).toEqual([
      {
        account: 'work',
        configured: true,
        state: 'idle',
        pendingOps: 2,
        notices: ['held folder'],
        unread: [],
        unreadCount: 0
      }
    ]);

    expect(today.recentSessions).toHaveLength(1);
    expect(today.recentSessions[0]).toEqual({
      id: 'sess-1',
      title: 'Chat with Lea',
      startedAt: '2026-07-16T08:00:00Z',
      status: 'ended',
      live: false
    });
  });

  it('accepts camelCase keys as a fallback', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mountKey: 'primary',
          icmName: 'Studio',
          ok: true,
          updatedAt: '2026-07-16T08:00:00Z',
          notes: null,
          prepared: [],
          tasks: { dueToday: 1, overdue: 0, inProgress: 0, top: [] }
        }
      ],
      mail: [{ account: 'zoe', configured: false, state: 'inactive', pending_ops: 1, notices: [] }],
      recentSessions: [
        { id: 'sess-2', title: 'Follow-up', startedAt: '2026-07-16T09:00:00Z', status: 'live', live: true }
      ]
    });

    expect(today.sections[0].mountKey).toBe('primary');
    expect(today.sections[0].icmName).toBe('Studio');
    expect(today.sections[0].tasks).toEqual({ dueToday: 1, overdue: 0, inProgress: 0, top: [] });
    expect(today.mail).toEqual([
      {
        account: 'zoe',
        configured: false,
        state: 'inactive',
        pendingOps: 1,
        notices: [],
        unread: [],
        unreadCount: 0
      }
    ]);
    expect(today.recentSessions[0].live).toBe(true);
  });

  it('tolerates missing collections, defaulting to empty sections/sessions/notices and zero/unconfigured mail', () => {
    const today = normalizeCockpitToday({});
    expect(today.sections).toEqual([]);
    expect(today.recentSessions).toEqual([]);
    expect(today.mail).toEqual([]);
    expect(today.scheduleNotices).toEqual([]);
  });

  it('drops wrong-typed fields to nil/[] rather than throwing', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mount_key: 'primary',
          icm_name: 'Studio',
          ok: true,
          updated_at: 42,
          notes: ['not a string'],
          prepared: [{ title: 'ok', summary: 7 }, 'not-a-map'],
          tasks: { due_today: 'lots', overdue: null, in_progress: 2, top: ['not-a-map', { id: 7, today: 'yes' }] }
        }
      ],
      mail: [{ account: 42, configured: 'yes', state: null, pending_ops: 'not-a-number', notices: ['ok', 7] }, 'not-a-map'],
      recent_sessions: 'nope'
    });

    const [section] = today.sections;
    expect(section.updatedAt).toBeNull();
    expect(section.notes).toBeNull();
    expect(section.prepared).toEqual([{ title: 'ok', summary: null, page: null }]);
    // Counts degrade to 0 rather than propagating NaN; a non-map top item is
    // dropped, and `today` is only ever set by a real JSON `true`.
    expect(section.tasks).toEqual({
      dueToday: 0,
      overdue: 0,
      inProgress: 2,
      top: [{ id: null, title: null, due: null, today: false, priority: null }]
    });

    // `pending_ops: 'not-a-number'` would `Number(...)` to `NaN` without the
    // `Number.isFinite` guard — degrades to 0 like every other wrong-typed
    // field in this normalizer, rather than propagating NaN into the UI.
    expect(today.mail).toEqual([
      { account: '', configured: false, state: '', pendingOps: 0, notices: ['ok'], unread: [], unreadCount: 0 }
    ]);
    expect(today.recentSessions).toEqual([]);
  });

  it('renders a section with ok:false and no prepared content, without dropping provenance', () => {
    const today = normalizeCockpitToday({
      sections: [
        {
          mount_key: 'primary',
          icm_name: 'Studio',
          ok: false,
          updated_at: null,
          notes: null,
          prepared: [],
          // The two files are independent: a broken `today.json` still has real
          // tasks to show, so the tasks line rides along on an `ok: false`
          // section (`Valea.Cockpit`'s `icm_section/1`).
          tasks: { due_today: 3, overdue: 0, in_progress: 0, top: [] }
        }
      ],
      mail: [],
      recent_sessions: []
    });

    const [section] = today.sections;
    expect(section.ok).toBe(false);
    expect(section.mountKey).toBe('primary');
    expect(section.icmName).toBe('Studio');
    expect(section.prepared).toEqual([]);
    expect(section.tasks).toEqual({ dueToday: 3, overdue: 0, inProgress: 0, top: [] });
  });

  // `tasks: null` is the UNREADABLE ledger — distinct from a zeroed line, which
  // is an absent or empty one. The Today page renders the calm note for the
  // first and the counts for the second.
  it('keeps an unreadable task ledger as null rather than zeroing it', () => {
    const today = normalizeCockpitToday({
      sections: [{ mount_key: 'primary', icm_name: 'Studio', ok: true, prepared: [], tasks: null }]
    });
    expect(today.sections[0].tasks).toBeNull();

    const missing = normalizeCockpitToday({
      sections: [{ mount_key: 'primary', icm_name: 'Studio', ok: true, prepared: [] }]
    });
    expect(missing.sections[0].tasks).toBeNull();

    // A wrong-typed line (a list, a string) is no more readable than a missing one.
    const wrongTyped = normalizeCockpitToday({
      sections: [{ mount_key: 'primary', icm_name: 'Studio', ok: true, prepared: [], tasks: 'nope' }]
    });
    expect(wrongTyped.sections[0].tasks).toBeNull();
  });

  it('normalizes a recent session with live:false to false, not falling back to true', () => {
    const today = normalizeCockpitToday({
      sections: [],
      mail: [],
      recent_sessions: [
        { id: 'sess-3', title: 'Ended session', started_at: '2026-07-16T07:00:00Z', status: 'ended', live: false }
      ]
    });

    expect(today.recentSessions[0].live).toBe(false);
  });
});

describe('mailSummaryLine', () => {
  it('formats one account as "slug: state · N pending"', () => {
    expect(
      mailSummaryLine({
        account: 'work',
        configured: true,
        state: 'idle',
        pendingOps: 2,
        notices: [],
        unread: [],
        unreadCount: 0
      })
    ).toBe('work: idle · 2 pending');
  });

  it('formats zero pending plainly', () => {
    expect(
      mailSummaryLine({
        account: 'zoe',
        configured: true,
        state: 'syncing',
        pendingOps: 0,
        notices: [],
        unread: [],
        unreadCount: 0
      })
    ).toBe('zoe: syncing · 0 pending');
  });
});

// -- Spec F calendar line -----------------------------------------------------

import { calendarSummaryLine } from './cockpit';

describe('calendar summary (Spec F)', () => {
  it('normalizes the camelCased typed shape (and a snake fallback) with a null next', () => {
    expect(normalizeCockpitToday({ calendar: { eventsToday: 3, next: null } }).calendar).toEqual({
      eventsToday: 3,
      next: null
    });
    expect(normalizeCockpitToday({ calendar: { events_today: 2, next: { time: '09:30', title: 'Standup' } } }).calendar)
      .toEqual({ eventsToday: 2, next: { time: '09:30', title: 'Standup' } });
    expect(normalizeCockpitToday({}).calendar).toBeNull();
    expect(normalizeCockpitToday({ calendar: null }).calendar).toBeNull();
  });

  it('renders the pinned line shape', () => {
    expect(calendarSummaryLine({ eventsToday: 3, next: { time: '09:30', title: 'Coffee with Priya' } })).toBe(
      '3 events today · next: 09:30 Coffee with Priya'
    );
    expect(calendarSummaryLine({ eventsToday: 1, next: null })).toBe('1 event today');
  });
});

// -- tasks+schedules: the cockpit tasks line + schedule notices ---------------

import { scheduleNoticeHref, scheduleNoticeText, tasksSummaryLine } from './cockpit';

describe('tasksSummaryLine', () => {
  it('joins only the non-zero counts, in the spec’s order', () => {
    expect(tasksSummaryLine({ dueToday: 2, overdue: 1, inProgress: 3, top: [] })).toBe(
      '2 due today · 1 overdue · 3 in progress'
    );
    expect(tasksSummaryLine({ dueToday: 0, overdue: 1, inProgress: 0, top: [] })).toBe('1 overdue');
    expect(tasksSummaryLine({ dueToday: 4, overdue: 0, inProgress: 0, top: [] })).toBe('4 due today');
  });

  it('falls back to an open count when nothing is due, overdue, or in flight', () => {
    const top = [{ id: 't-1', title: 'Someday', due: null, today: false, priority: null }];
    expect(tasksSummaryLine({ dueToday: 0, overdue: 0, inProgress: 0, top })).toBe('1 open');
  });

  it('is null for a genuinely quiet ledger — a "0 due today" line would be noise', () => {
    expect(tasksSummaryLine({ dueToday: 0, overdue: 0, inProgress: 0, top: [] })).toBeNull();
  });
});

describe('schedule notices', () => {
  it('normalizes the camelCased array-item keys, and the snake fallback', () => {
    const today = normalizeCockpitToday({
      scheduleNotices: [
        { kind: 'failed', mountKey: 'primary', scheduleId: 's-1', title: 'Nightly sync', at: '2026-07-30T02:00:00Z' },
        { kind: 'registered', mount_key: 'clients', schedule_id: 's-2', title: 'Weekly brief', at: null }
      ]
    });

    expect(today.scheduleNotices).toEqual([
      { kind: 'failed', mountKey: 'primary', scheduleId: 's-1', title: 'Nightly sync', at: '2026-07-30T02:00:00Z' },
      { kind: 'registered', mountKey: 'clients', scheduleId: 's-2', title: 'Weekly brief', at: null }
    ]);
  });

  it('drops a notice with no kind or no schedule id — nothing to say or link', () => {
    const today = normalizeCockpitToday({
      schedule_notices: [{ kind: 'failed' }, { schedule_id: 's-3' }, 'not-a-map', { kind: 'waiting', schedule_id: 's-4' }]
    });
    expect(today.scheduleNotices).toEqual([
      // A missing title falls back to the id, so an unlabeled notice still says which schedule.
      { kind: 'waiting', mountKey: null, scheduleId: 's-4', title: 's-4', at: null }
    ]);
  });

  it('phrases each kind, and echoes an unknown one rather than hiding it', () => {
    expect(scheduleNoticeText({ kind: 'waiting', mountKey: 'p', scheduleId: 's', title: 'Brief', at: null })).toBe(
      'Brief is waiting for your approval'
    );
    expect(scheduleNoticeText({ kind: 'failed', mountKey: 'p', scheduleId: 's', title: 'Sync', at: null })).toBe(
      'Sync failed'
    );
    expect(scheduleNoticeText({ kind: 'registered', mountKey: 'p', scheduleId: 's', title: 'Brief', at: null })).toBe(
      'Brief was registered'
    );
    expect(scheduleNoticeText({ kind: 'invented', mountKey: 'p', scheduleId: 's', title: 'X', at: null })).toBe(
      'X: invented'
    );
  });

  it('sends every kind to the Schedules tab — where the transcript link and output live', () => {
    for (const kind of ['waiting', 'failed', 'registered']) {
      expect(scheduleNoticeHref({ kind, mountKey: 'p', scheduleId: 's', title: 'X', at: null })).toBe(
        '/tasks?tab=schedules'
      );
    }
  });
});

// ICM git sync: the cockpit's `git` block is a THIRD delivery of
// `Valea.Git.Engine.public_rows/1`'s rows (the RPC and the `git_status` push
// are the other two), so the normalizer is the store's — this only pins that
// the payload key is read and the rows survive the trip.
describe('git block', () => {
  it('normalizes the snake_case rows the engine publishes', () => {
    const today = normalizeCockpitToday({
      git: [
        {
          mount_key: 'workspace',
          icm_name: 'workspace',
          mode: 'full',
          state: 'diverged',
          reason: null,
          branch: 'main',
          ahead: 1,
          behind: 2,
          dirty: false,
          local_sha: 'aaa',
          remote_sha: 'bbb',
          last_sync_at: '2026-07-30T08:00:00Z',
          last_error: null,
          conflict_session_id: null
        }
      ]
    });

    expect(today.git).toHaveLength(1);
    expect(today.git[0]).toMatchObject({
      mountKey: 'workspace',
      state: 'diverged',
      ahead: 1,
      behind: 2,
      lastSyncAt: '2026-07-30T08:00:00Z'
    });
  });

  it('is an empty list when the payload has no git block at all', () => {
    expect(normalizeCockpitToday({}).git).toEqual([]);
  });
});
