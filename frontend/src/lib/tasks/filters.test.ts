import { describe, expect, it } from 'vitest';
import {
  addDaysIso,
  applyTaskFilters,
  countByStatus,
  dueBucket,
  dueDate,
  groupByDue,
  groupByPriority,
  isCompleted,
  isKnownStatus,
  localDateIso,
  matchesSearch,
  nextUp,
  normalizeTask,
  orderTaskRows,
  overdueDays,
  overduePillText,
  priorityGlyph,
  sortTasks,
  splitOverdue,
  todayFilter,
  type TaskEntry
} from './filters';

const TODAY = '2026-07-30';

/** Builds a normalized entry from the FILE's own key spelling — what `list_tasks` actually delivers. */
function task(fields: Record<string, unknown>): TaskEntry {
  return normalizeTask({ id: 't-1', title: 'A task', status: 'open', ...fields });
}

describe('normalizeTask', () => {
  it('reads the file keys, defaults a missing status to "", and keeps the raw map', () => {
    const raw = {
      id: 't-8f3a2c',
      title: 'Send Kita offer follow-up',
      notes: 'freeform',
      status: 'open',
      assignee: 'user',
      due: '2026-07-30',
      today: true,
      priority: 'high',
      source: 'mail:w3d/INBOX/<msg_id>',
      created_by: 'agent',
      created_at: '2026-07-29T08:00:00Z',
      updated_at: '2026-07-29T08:00:00Z',
      done_at: null,
      // A field Valea doesn't understand — preserved for round-tripping.
      colour: 'green'
    };

    const entry = normalizeTask(raw);

    expect(entry).toMatchObject({
      id: 't-8f3a2c',
      title: 'Send Kita offer follow-up',
      notes: 'freeform',
      status: 'open',
      assignee: 'user',
      due: '2026-07-30',
      today: true,
      priority: 'high',
      source: 'mail:w3d/INBOX/<msg_id>',
      createdBy: 'agent',
      createdAt: '2026-07-29T08:00:00Z',
      updatedAt: '2026-07-29T08:00:00Z',
      doneAt: null
    });
    expect(entry.raw).toBe(raw);
    expect(entry.raw.colour).toBe('green');
  });

  it('degrades wrong-typed display fields to null rather than rendering them', () => {
    const entry = normalizeTask({ id: 7, title: ['x'], notes: {}, status: 42, priority: 1, source: false, due: 20260730 });

    expect(entry.id).toBeNull();
    expect(entry.title).toBeNull();
    expect(entry.notes).toBeNull();
    expect(entry.status).toBe('');
    expect(entry.priority).toBeNull();
    expect(entry.source).toBeNull();
    expect(entry.due).toBeNull();
  });

  it('treats `today` as set ONLY for a real JSON true', () => {
    expect(normalizeTask({ today: true }).today).toBe(true);
    expect(normalizeTask({ today: 'true' }).today).toBe(false);
    expect(normalizeTask({ today: 1 }).today).toBe(false);
    expect(normalizeTask({}).today).toBe(false);
  });
});

describe('dueDate', () => {
  it('accepts a plain calendar date and nothing else', () => {
    expect(dueDate(task({ due: '2026-07-30' }))).toBe('2026-07-30');
    expect(dueDate(task({ due: '2026-07-30T08:00:00Z' }))).toBeNull();
    expect(dueDate(task({ due: 'tomorrow' }))).toBeNull();
    expect(dueDate(task({ due: '2026-13-01' }))).toBeNull();
    expect(dueDate(task({ due: '2026-02-30' }))).toBeNull();
    expect(dueDate(task({}))).toBeNull();
  });
});

// Review round 1, L6: the route re-reads this on a timer, so an app left open
// across midnight stops filtering against yesterday.
describe('localDateIso', () => {
  it('reports the LOCAL calendar date, not the UTC one', () => {
    // Local midnight and one minute before it are the same local day, whatever
    // the host zone — the UTC reading of at least one of them is not.
    const midnight = new Date(2026, 6, 30, 0, 0, 0);
    const lateEvening = new Date(2026, 6, 30, 23, 59, 0);

    expect(localDateIso(midnight)).toBe('2026-07-30');
    expect(localDateIso(lateEvening)).toBe('2026-07-30');
    // One minute later is a new day, which is the whole point of re-reading it.
    expect(localDateIso(new Date(2026, 6, 31, 0, 0, 0))).toBe('2026-07-31');
  });

  it('zero-pads month and day, so the string compares lexically against a due date', () => {
    expect(localDateIso(new Date(2026, 0, 5, 12, 0, 0))).toBe('2026-01-05');
    expect(dueDate(task({ due: localDateIso(new Date(2026, 0, 5, 12, 0, 0)) }))).toBe('2026-01-05');
  });
});

describe('todayFilter', () => {
  it('includes due-today, overdue, the today flag, and in_progress regardless of due', () => {
    const dueToday = task({ id: 'due-today', due: TODAY });
    const overdue = task({ id: 'overdue', due: '2026-07-01' });
    const flagged = task({ id: 'flagged', today: true });
    const inProgress = task({ id: 'in-progress', status: 'in_progress' });
    const inProgressFuture = task({ id: 'in-progress-later', status: 'in_progress', due: '2026-12-01' });
    const later = task({ id: 'later', due: '2026-08-30' });
    const undated = task({ id: 'undated' });

    const kept = todayFilter([dueToday, overdue, flagged, inProgress, inProgressFuture, later, undated], TODAY).map(
      (t) => t.id
    );

    expect(kept).toEqual(['due-today', 'overdue', 'flagged', 'in-progress', 'in-progress-later']);
  });

  it('excludes completed entries even when they are flagged or overdue', () => {
    const done = task({ id: 'done', today: true, status: 'done', due: '2026-07-01' });
    const dropped = task({ id: 'dropped', today: true, status: 'dropped' });
    const open = task({ id: 'open', today: true });

    expect(todayFilter([done, dropped, open], TODAY).map((t) => t.id)).toEqual(['open']);
  });

  it('keeps an unknown-status entry that qualifies — leniency, not exclusion', () => {
    const weird = task({ id: 'weird', status: 'blocked', today: true });
    expect(todayFilter([weird], TODAY).map((t) => t.id)).toEqual(['weird']);
  });
});

describe('sortTasks', () => {
  it('orders today-flag first, then due ascending, then priority, then created_at', () => {
    const rows = [
      task({ id: 'later-low', due: '2026-08-02', priority: 'low' }),
      task({ id: 'flagged-late', today: true, due: '2026-09-09' }),
      task({ id: 'later-high', due: '2026-08-02', priority: 'high' }),
      task({ id: 'flagged-early', today: true, due: '2026-08-01' }),
      task({ id: 'soon', due: '2026-07-31' })
    ];

    expect(sortTasks(rows).map((t) => t.id)).toEqual([
      'flagged-early',
      'flagged-late',
      'soon',
      'later-high',
      'later-low'
    ]);
  });

  it('sorts an entry with no parseable due after every dated one', () => {
    const rows = [task({ id: 'undated' }), task({ id: 'dated', due: '2026-12-31' }), task({ id: 'junk', due: 'soon' })];
    expect(sortTasks(rows).map((t) => t.id)).toEqual(['dated', 'undated', 'junk']);
  });

  it('ranks priority high > medium > low > unknown/absent', () => {
    const rows = [
      task({ id: 'none' }),
      task({ id: 'low', priority: 'low' }),
      task({ id: 'urgent', priority: 'urgent' }),
      task({ id: 'high', priority: 'high' }),
      task({ id: 'medium', priority: 'medium' })
    ];
    expect(sortTasks(rows).map((t) => t.id)).toEqual(['high', 'medium', 'low', 'none', 'urgent']);
  });

  it('breaks a full tie on created_at ascending, with a missing stamp last', () => {
    const rows = [
      task({ id: 'no-stamp' }),
      task({ id: 'newer', created_at: '2026-07-29T10:00:00Z' }),
      task({ id: 'older', created_at: '2026-07-01T10:00:00Z' })
    ];
    expect(sortTasks(rows).map((t) => t.id)).toEqual(['older', 'newer', 'no-stamp']);
  });

  it('is stable for entries equal on every key — file order decides, so "first wins" is visible', () => {
    const rows = [task({ id: 'first' }), task({ id: 'second' }), task({ id: 'third' })];
    expect(sortTasks(rows).map((t) => t.id)).toEqual(['first', 'second', 'third']);
  });

  it('does not mutate its input', () => {
    const rows = [task({ id: 'b', due: '2026-08-02' }), task({ id: 'a', due: '2026-08-01' })];
    sortTasks(rows);
    expect(rows.map((t) => t.id)).toEqual(['b', 'a']);
  });
});

describe('orderTaskRows', () => {
  it('sinks unknown statuses below every known-status row, each half sorted', () => {
    const rows = [
      task({ id: 'blocked-flagged', status: 'blocked', today: true }),
      task({ id: 'open-later', due: '2026-09-01' }),
      task({ id: 'open-flagged', today: true }),
      task({ id: 'empty-status', status: '' })
    ];

    expect(orderTaskRows(rows).map((t) => t.id)).toEqual([
      'open-flagged',
      'open-later',
      'blocked-flagged',
      'empty-status'
    ]);
  });
});

describe('isKnownStatus / isCompleted', () => {
  it('knows exactly the four statuses `Valea.Tasks` defines', () => {
    expect(['open', 'in_progress', 'done', 'dropped'].every(isKnownStatus)).toBe(true);
    expect(isKnownStatus('blocked')).toBe(false);
    expect(isKnownStatus('')).toBe(false);
  });

  it('counts done and dropped as completed', () => {
    expect(isCompleted(task({ status: 'done' }))).toBe(true);
    expect(isCompleted(task({ status: 'dropped' }))).toBe(true);
    expect(isCompleted(task({ status: 'open' }))).toBe(false);
    expect(isCompleted(task({ status: 'blocked' }))).toBe(false);
  });
});

describe('applyTaskFilters', () => {
  const rows = [
    task({ id: 'flagged', today: true, assignee: 'user' }),
    task({ id: 'agent-work', status: 'in_progress', assignee: 'agent' }),
    task({ id: 'someday', due: '2026-12-01', assignee: 'user' }),
    task({ id: 'finished', status: 'done', assignee: 'user' })
  ];

  it('defaults to the Today view', () => {
    expect(applyTaskFilters(rows, { view: 'today', assignee: null, status: null }, TODAY).map((t) => t.id)).toEqual([
      'flagged',
      'agent-work'
    ]);
  });

  // Ordering is `orderTaskRows`', not file order: the flagged entry leads,
  // then the only dated one, then the two undated ones in file order (a
  // completed entry is NOT sunk — only unknown statuses are).
  it('All shows every entry, completed included, in the tab order', () => {
    expect(applyTaskFilters(rows, { view: 'all', assignee: null, status: null }, TODAY).map((t) => t.id)).toEqual([
      'flagged',
      'someday',
      'agent-work',
      'finished'
    ]);
  });

  it('narrows by assignee, treating an absent assignee as "user"', () => {
    const noAssignee = task({ id: 'no-assignee', today: true });
    const all = [...rows, noAssignee];

    expect(applyTaskFilters(all, { view: 'all', assignee: 'agent', status: null }, TODAY).map((t) => t.id)).toEqual([
      'agent-work'
    ]);
    expect(applyTaskFilters(all, { view: 'today', assignee: 'user', status: null }, TODAY).map((t) => t.id)).toEqual([
      'flagged',
      'no-assignee'
    ]);
  });

  it('an explicit status chip can surface a completed entry inside the Today view', () => {
    expect(applyTaskFilters(rows, { view: 'today', assignee: null, status: 'done' }, TODAY)).toEqual([]);
    expect(applyTaskFilters(rows, { view: 'all', assignee: null, status: 'done' }, TODAY).map((t) => t.id)).toEqual([
      'finished'
    ]);
  });
});

describe('countByStatus', () => {
  it('counts exact status matches, unknown statuses included', () => {
    const rows = [task({ status: 'open' }), task({ status: 'open' }), task({ status: 'blocked' })];
    expect(countByStatus(rows, 'open')).toBe(2);
    expect(countByStatus(rows, 'blocked')).toBe(1);
    expect(countByStatus(rows, 'done')).toBe(0);
  });
});

// -- redesign additions (spec 2026-08-06) -------------------------------------
//
// Nested so this half can keep the spec's own `TODAY` (2026-08-06) and its
// status-less `t` builder without disturbing the constants the tests above
// were written against.
describe('redesign additions', () => {
  const t = (raw: Record<string, unknown>) => normalizeTask({ id: 'x', title: 't', ...raw });
  const TODAY = '2026-08-06';

  describe('overdue maths', () => {
    it('counts days over, string-date math, month boundary', () => {
      expect(overdueDays(t({ due: '2026-08-04' }), TODAY)).toBe(2);
      expect(overdueDays(t({ due: '2026-07-31' }), '2026-08-01')).toBe(1);
    });
    it('null for today, future, unparseable, and completed-irrelevant absent due', () => {
      expect(overdueDays(t({ due: TODAY }), TODAY)).toBeNull();
      expect(overdueDays(t({ due: '2026-08-08' }), TODAY)).toBeNull();
      expect(overdueDays(t({ due: 'soonish' }), TODAY)).toBeNull();
      expect(overdueDays(t({}), TODAY)).toBeNull();
    });
    it('pill text singular/plural', () => {
      expect(overduePillText(1)).toBe('1 day over');
      expect(overduePillText(3)).toBe('3 days over');
    });
    it('addDaysIso crosses months and years', () => {
      expect(addDaysIso('2026-08-30', 7)).toBe('2026-09-06');
      expect(addDaysIso('2026-12-28', 7)).toBe('2027-01-04');
    });
  });

  describe('priorityGlyph', () => {
    it('maps the three known priorities and returns null otherwise', () => {
      expect(priorityGlyph('high')).toEqual({ glyph: '‼', tone: 'high' });
      expect(priorityGlyph('medium')).toEqual({ glyph: '!', tone: 'medium' });
      expect(priorityGlyph('low')).toEqual({ glyph: '·', tone: 'low' });
      expect(priorityGlyph(null)).toBeNull();
      expect(priorityGlyph('urgent')).toBeNull(); // unknown → text chip elsewhere, not a glyph
    });
  });

  describe('matchesSearch', () => {
    it('case-insensitive substring over title and notes; blank query matches all', () => {
      const task = t({ title: 'Rechnung Kita', notes: 'CHF 500 offen' });
      expect(matchesSearch(task, 'kita')).toBe(true);
      expect(matchesSearch(task, 'chf')).toBe(true);
      expect(matchesSearch(task, 'zzz')).toBe(false);
      expect(matchesSearch(task, '  ')).toBe(true);
      expect(matchesSearch(t({ title: null, notes: null }), 'x')).toBe(false);
    });
  });

  describe('dueBucket / groupByDue', () => {
    it('buckets overdue/today/week/later/none', () => {
      expect(dueBucket(t({ due: '2026-08-01' }), TODAY)).toBe('overdue');
      expect(dueBucket(t({ due: TODAY }), TODAY)).toBe('today');
      expect(dueBucket(t({ due: '2026-08-13' }), TODAY)).toBe('week'); // today+7 inclusive
      expect(dueBucket(t({ due: '2026-08-14' }), TODAY)).toBe('later');
      expect(dueBucket(t({}), TODAY)).toBe('none');
      expect(dueBucket(t({ due: 'nope' }), TODAY)).toBe('none');
    });
    it('groupByDue emits only non-empty buckets, Overdue first, labeled', () => {
      const rows = [t({ id: 'a', due: '2026-08-20' }), t({ id: 'b', due: '2026-08-01' })];
      const groups = groupByDue(rows, TODAY);
      expect(groups.map((g) => g.key)).toEqual(['overdue', 'later']);
      expect(groups[0].label).toBe('Overdue');
      expect(groups.find((g) => g.key === 'later')!.label).toBe('Later');
    });
  });

  describe('groupByPriority', () => {
    it('High/Medium/Low/None order, unknown priorities join None, empty buckets dropped', () => {
      const rows = [
        t({ id: 'a', priority: 'low' }),
        t({ id: 'b', priority: 'urgent' }),
        t({ id: 'c', priority: 'high' })
      ];
      const groups = groupByPriority(rows);
      expect(groups.map((g) => g.label)).toEqual(['High', 'Low', 'None']);
      expect(groups[2].rows.map((r) => r.id)).toEqual(['b']);
    });
  });

  describe('splitOverdue', () => {
    it('overdue oldest-due first; rest keeps incoming order', () => {
      const rows = [
        t({ id: 'later', due: '2026-08-09' }),
        t({ id: 'worse', due: '2026-08-01' }),
        t({ id: 'bad', due: '2026-08-04' })
      ];
      const { overdue, rest } = splitOverdue(rows, TODAY);
      expect(overdue.map((r) => r.id)).toEqual(['worse', 'bad']);
      expect(rest.map((r) => r.id)).toEqual(['later']);
    });
  });

  describe('nextUp', () => {
    it('open backlog only (not today-view, not completed), standard sort, capped', () => {
      const rows = [
        t({ id: 'in-today', today: true }),
        t({ id: 'done', status: 'done' }),
        t({ id: 'p-high', priority: 'high' }),
        t({ id: 'p-low', priority: 'low' }),
        t({ id: 'dated', due: '2026-09-01' })
      ];
      expect(nextUp(rows, TODAY, 2).map((r) => r.id)).toEqual(['dated', 'p-high']);
    });
  });
});
