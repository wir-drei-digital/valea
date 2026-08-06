import { describe, expect, it } from 'vitest';
import { normalizeTask } from './filters';
import { DEFAULT_BOARD_STATUSES, boardLabel, deriveColumns, dropPatch } from './board';

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
