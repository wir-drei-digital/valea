/**
 * Persisted filter settings for the Tasks page + the Today assignee toggle
 * (spec §Persistence). One store so there is exactly one owner of the two
 * storage keys. Write paths are `untrack`ed — a store method that reads its
 * own `$state` while writing subscribes the CALLER to that state, the
 * `theme.svelte.ts` bug class this repo already fixed once.
 *
 * The class is exported alongside the singleton (as `ThemeStore` is beside
 * `themeStore`) so tests can build an instance in their OWN module graph.
 * `vi.resetModules()` + `await import()` gives the re-imported module a SECOND
 * copy of the svelte client runtime, whose `$state` no effect in the test file
 * can subscribe to — a reactivity pin written against such an instance passes
 * whatever this file does. See `settings.test.svelte.ts`.
 */
import { untrack } from 'svelte';
import { readJson, writeJson } from '../persist';
import {
  TASKS_FILTERS_KEY,
  TODAY_ASSIGNEE_KEY,
  decodeTasksFilterSettings,
  decodeTodayAssignee,
  type TasksFilterSettings
} from './settings';

export class TasksSettingsStore {
  filters = $state<TasksFilterSettings>(decodeTasksFilterSettings(readJson(TASKS_FILTERS_KEY)));
  todayAssignee = $state<'user' | null>(decodeTodayAssignee(readJson(TODAY_ASSIGNEE_KEY)));

  setFilters(patch: Partial<TasksFilterSettings>): void {
    untrack(() => {
      this.filters = { ...this.filters, ...patch };
      writeJson(TASKS_FILTERS_KEY, this.filters);
    });
  }

  setTodayAssignee(value: 'user' | null): void {
    untrack(() => {
      this.todayAssignee = value;
      writeJson(TODAY_ASSIGNEE_KEY, value);
    });
  }
}

export const tasksSettings = new TasksSettingsStore();
