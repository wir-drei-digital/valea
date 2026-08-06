import type { TaskFilter } from './filters';

export type TasksViewMode = 'list' | 'board';
export type TasksGroupBy = 'project' | 'priority' | 'due';

/** The Tasks page's persisted filter set (spec §Persistence). Search text and "Show done" expansions are session-local and never stored. */
export type TasksFilterSettings = {
  mode: TasksViewMode;
  view: TaskFilter;
  assignee: 'user' | 'agent' | null;
  groupBy: TasksGroupBy;
};

export const TASKS_FILTERS_KEY = 'valea.tasks.filters';
export const TODAY_ASSIGNEE_KEY = 'valea.today.assignee';

export const DEFAULT_TASKS_FILTER_SETTINGS: TasksFilterSettings = {
  mode: 'list',
  view: 'today',
  assignee: null,
  groupBy: 'project'
};

/**
 * Field-wise decode: each stored field falls back ALONE, so one unknown enum
 * value (a future release's setting, a hand-edited store) never resets the
 * neighbours the user still recognizes.
 */
export function decodeTasksFilterSettings(raw: unknown): TasksFilterSettings {
  const rec = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  return {
    mode: rec.mode === 'board' ? 'board' : DEFAULT_TASKS_FILTER_SETTINGS.mode,
    view: rec.view === 'all' ? 'all' : DEFAULT_TASKS_FILTER_SETTINGS.view,
    assignee: rec.assignee === 'user' || rec.assignee === 'agent' ? rec.assignee : null,
    groupBy:
      rec.groupBy === 'priority' || rec.groupBy === 'due' ? rec.groupBy : DEFAULT_TASKS_FILTER_SETTINGS.groupBy
  };
}

/** Today-page toggle: only the literal 'user' narrows to Mine; anything else is Everyone. */
export function decodeTodayAssignee(raw: unknown): 'user' | null {
  return raw === 'user' ? 'user' : null;
}
