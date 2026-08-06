import { describe, expect, it } from 'vitest';
import {
  DEFAULT_TASKS_FILTER_SETTINGS,
  decodeTasksFilterSettings,
  decodeTodayAssignee
} from './settings';

describe('decodeTasksFilterSettings', () => {
  it('accepts a full valid record', () => {
    expect(
      decodeTasksFilterSettings({ mode: 'board', view: 'all', assignee: 'agent', groupBy: 'due' })
    ).toEqual({ mode: 'board', view: 'all', assignee: 'agent', groupBy: 'due' });
  });

  it('degrades FIELD-WISE: unknown values fall back alone, valid neighbours survive', () => {
    expect(
      decodeTasksFilterSettings({ mode: 'kanban', view: 'all', assignee: 'boss', groupBy: 'due' })
    ).toEqual({ mode: 'list', view: 'all', assignee: null, groupBy: 'due' });
  });

  it('returns defaults for null, arrays, strings', () => {
    for (const raw of [null, undefined, [], 'x', 42]) {
      expect(decodeTasksFilterSettings(raw)).toEqual(DEFAULT_TASKS_FILTER_SETTINGS);
    }
  });

  it('assignee null is a VALID stored value, not a fallback marker', () => {
    expect(decodeTasksFilterSettings({ assignee: null }).assignee).toBeNull();
    expect(decodeTasksFilterSettings({ assignee: 'user' }).assignee).toBe('user');
  });
});

describe('decodeTodayAssignee', () => {
  it("only the literal 'user' narrows; everything else is null (Everyone)", () => {
    expect(decodeTodayAssignee('user')).toBe('user');
    for (const raw of [null, 'agent', 'boss', 1, {}]) expect(decodeTodayAssignee(raw)).toBeNull();
  });
});
