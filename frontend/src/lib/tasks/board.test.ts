import { describe, expect, it } from 'vitest';
import { normalizeTask } from './filters';
import { DEFAULT_BOARD_STATUSES, boardLabel, boardTask, boardTasks, deriveColumns, dropPatch } from './board';

const t = (raw: Record<string, unknown>) => normalizeTask({ id: 'x', title: 't', ...raw });

describe('deriveColumns', () => {
  it('always emits Open · In progress · Done, in order, even empty', () => {
    expect(deriveColumns([]).map((c) => c.status)).toEqual([...DEFAULT_BOARD_STATUSES]);
    expect(deriveColumns([]).every((c) => !c.custom)).toBe(true);
  });

  it('empty-string status lands in Open (the resting state)', () => {
    const cols = deriveColumns([t({ id: 'a', status: '' })]);
    expect(cols.find((c) => c.status === 'open')!.tasks.map((x) => x.id)).toEqual(['a']);
  });

  it('custom statuses get their own columns after the defaults, first-seen order, verbatim label', () => {
    const cols = deriveColumns([
      t({ id: 'a', status: 'waiting' }),
      t({ id: 'b', status: 'blocked' }),
      t({ id: 'c', status: 'waiting' })
    ]);
    expect(cols.map((c) => c.status)).toEqual(['open', 'in_progress', 'done', 'waiting', 'blocked']);
    const waiting = cols.find((c) => c.status === 'waiting')!;
    expect(waiting.custom).toBe(true);
    expect(waiting.label).toBe('waiting');
    expect(waiting.tasks.map((x) => x.id)).toEqual(['a', 'c']);
  });

  it('dropped never gets a column and dropped entries appear nowhere', () => {
    const cols = deriveColumns([t({ id: 'a', status: 'dropped' })]);
    expect(cols.map((c) => c.status)).toEqual([...DEFAULT_BOARD_STATUSES]);
    expect(cols.flatMap((c) => c.tasks)).toEqual([]);
  });

  it('column rows are orderTaskRows-sorted', () => {
    const cols = deriveColumns([
      t({ id: 'later', status: 'open', due: '2026-09-01' }),
      t({ id: 'urgent', status: 'open', today: true })
    ]);
    expect(cols[0].tasks.map((x) => x.id)).toEqual(['urgent', 'later']);
  });
});

describe('boardTasks', () => {
  it('appends the receipts the view filter left out, after the view rows', () => {
    const open = t({ id: 'a', status: 'open', today: true });
    const receipt = t({ id: 'b', status: 'done' });
    expect(boardTasks([open], [receipt]).map((x) => x.id)).toEqual(['a', 'b']);
  });

  it('drops a receipt already in the rows (the All view, where the union is a no-op)', () => {
    const open = t({ id: 'a', status: 'open' });
    const receipt = t({ id: 'b', status: 'done' });
    expect(boardTasks([open, receipt], [receipt]).map((x) => x.id)).toEqual(['a', 'b']);
  });

  it('dedupes by IDENTITY, so twins sharing an id both survive', () => {
    // Two entries, one id — the leniency contract renders both, and an
    // id-keyed dedupe would have swallowed the second.
    const shown = t({ id: 'dup', status: 'done' });
    const twin = t({ id: 'dup', status: 'done' });
    expect(boardTasks([shown], [shown, twin])).toEqual([shown, twin]);
  });

  it('is the plain row set when there are no receipts', () => {
    const rows = [t({ id: 'a' }), t({ id: 'b' })];
    expect(boardTasks(rows, [])).toEqual(rows);
  });
});

describe('boardTask', () => {
  it('normalizes an empty status to open, keeping every other field', () => {
    const task = boardTask(t({ id: 'a', status: '', title: 'plan' }));
    expect(task.status).toBe('open');
    expect(task.title).toBe('plan');
    // A display projection only — the file's own value stays in `raw`.
    expect(task.raw.status).toBe('');
  });

  it('returns the SAME entry when nothing changes (the board maps cards back by identity)', () => {
    const task = t({ id: 'a', status: 'in_progress' });
    expect(boardTask(task)).toBe(task);
    expect(boardTask(task, 'in_progress')).toBe(task);
  });

  it('a pending drop wins over the file, so the card sits in the column it was dropped on', () => {
    const task = t({ id: 'a', status: 'open' });
    expect(boardTask(task, 'waiting').status).toBe('waiting');
    expect(task.status).toBe('open');
  });

  it('puts a today-flagged no-status card FIRST in Open — the list partition would sort it last', () => {
    const flagged = t({ id: 'flagged', status: '', today: true });
    const calm = t({ id: 'calm', status: 'open' });

    const prepared = deriveColumns([flagged, calm].map((task) => boardTask(task)));
    expect(prepared[0].tasks.map((x) => x.id)).toEqual(['flagged', 'calm']);

    // Without the normalization: `orderTaskRows` files `""` with the unknown
    // statuses, which on the board reads as a sorting glitch (the column is
    // already the status, so there is no chip explaining the split).
    expect(deriveColumns([flagged, calm])[0].tasks.map((x) => x.id)).toEqual(['calm', 'flagged']);
  });
});

describe('boardLabel', () => {
  it('titles the known trio, passes custom through verbatim', () => {
    expect(boardLabel('open')).toBe('Open');
    expect(boardLabel('in_progress')).toBe('In progress');
    expect(boardLabel('done')).toBe('Done');
    expect(boardLabel('Waiting on Nadja')).toBe('Waiting on Nadja');
  });
});

describe('dropPatch', () => {
  it('patches to the target column status verbatim, including custom columns', () => {
    expect(dropPatch(t({ id: 'a', status: 'open' }), 'waiting')).toEqual({ status: 'waiting' });
  });
  it('null for same-column drops, id-less tasks, and empty-string-status→open no-ops', () => {
    expect(dropPatch(t({ id: 'a', status: 'done' }), 'done')).toBeNull();
    expect(dropPatch(normalizeTask({ title: 'no id', status: 'open' }), 'done')).toBeNull();
    expect(dropPatch(t({ id: 'a', status: '' }), 'open')).toBeNull();
  });
});
