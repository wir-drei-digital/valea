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

  /**
   * Decoded on the way IN as well as out, the rule `theme.svelte.ts` states as
   * "memory must not hold what a reload would reject". `Partial` admits an
   * explicit `undefined` (clearing a facet off a UI control), and the UI also
   * hands enums over an unchecked cast; the codec is total and idempotent on
   * valid values, so honest callers keep exactly the merge semantics they had.
   *
   * The undefined case is the sharp one: `JSON.stringify` DROPS an
   * undefined-valued key, so an unsanitised merge would leave memory holding
   * `undefined` and storage holding no key — two states, neither of which is a
   * value the store ever agreed to.
   */
  setFilters(patch: Partial<TasksFilterSettings>): void {
    untrack(() => {
      this.filters = decodeTasksFilterSettings({ ...this.filters, ...patch });
      writeJson(TASKS_FILTERS_KEY, this.filters);
    });
  }

  /** Same rule as `setFilters`, and it persists what MEMORY holds, not `value` — one decode, one truth. */
  setTodayAssignee(value: 'user' | null): void {
    untrack(() => {
      this.todayAssignee = decodeTodayAssignee(value);
      writeJson(TODAY_ASSIGNEE_KEY, this.todayAssignee);
    });
  }
}

export const tasksSettings = new TasksSettingsStore();
