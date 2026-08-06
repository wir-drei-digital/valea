/**
 * The reactive half of the settings pair: this file covers the STORE
 * (`settings.svelte.ts`), while `settings.test.ts` covers the pure codec
 * (`settings.ts`) — the same split `theme.test.svelte.ts` / `theme.test.ts`
 * uses one directory over.
 *
 * It runs under the `runes` project (see `vite.config.ts`), which supplies the
 * client transform. That matters: compiled as SSR, `$state` becomes a plain
 * value and `$effect` compiles away to nothing, so the untrack pins below
 * would exercise no effects at all and pass no matter what the store does.
 *
 * Deliberately NO per-file environment pragma. Vitest greps the whole file for
 * that directive and takes the next word as an environment NAME, so merely
 * mentioning the directive in prose is enough to make it resolve something like
 * `header` and fail the file before a single test runs. The `at`-sigil spelling
 * is avoided above for exactly that reason.
 */
import { describe, expect, it, vi, afterEach } from 'vitest';
import { flushSync } from 'svelte';
import { TasksSettingsStore } from './settings.svelte';
import {
  TASKS_FILTERS_KEY,
  TODAY_ASSIGNEE_KEY,
  decodeTasksFilterSettings,
  type TasksViewMode
} from './settings';

/**
 * Fresh module per test: the SINGLETON reads storage at construction, and that
 * seeding is the thing these first four tests are about.
 *
 * Only for those. `vi.resetModules()` makes the re-imported module pull a
 * SECOND copy of the svelte client runtime — measured, not assumed: after the
 * reset, `(await import('svelte')).untrack` is not the `untrack` a static
 * import of the same specifier resolves to in this file. A store built
 * that way keeps its `$state` in a reactivity system this file's `$effect`
 * cannot see, so it can neither wake a reader nor enrol one, and every
 * reactivity assertion against it holds vacuously. The pins below therefore use
 * `new TasksSettingsStore()` from the static import above, which shares this
 * file's runtime.
 */
async function freshStore() {
  vi.resetModules();
  const mod = await import('./settings.svelte');
  return mod.tasksSettings;
}

function stubStorage(seed: Record<string, string> = {}) {
  const store = new Map(Object.entries(seed));
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v)
  });
  return store;
}

afterEach(() => vi.unstubAllGlobals());

describe('tasksSettings', () => {
  it('seeds BOTH keys from storage, field-wise', async () => {
    stubStorage({
      [TASKS_FILTERS_KEY]: JSON.stringify({ mode: 'board', groupBy: 'nope' }),
      [TODAY_ASSIGNEE_KEY]: JSON.stringify('user')
    });
    const s = await freshStore();
    expect(s.filters.mode).toBe('board');
    expect(s.filters.groupBy).toBe('project');
    // Seeded too, or only this key's WRITE path would be covered and a
    // constructor reading the wrong key would pass every other test here.
    expect(s.todayAssignee, 'the Today toggle must survive a reload').toBe('user');
  });

  it('setFilters merges a patch and persists the WHOLE record', async () => {
    const store = stubStorage();
    const s = await freshStore();
    s.setFilters({ view: 'all' });
    expect(s.filters.view).toBe('all');
    expect(JSON.parse(store.get(TASKS_FILTERS_KEY)!)).toEqual(s.filters);
  });

  it('today assignee round-trips its own key', async () => {
    const store = stubStorage();
    const s = await freshStore();
    s.setTodayAssignee('user');
    expect(store.get(TODAY_ASSIGNEE_KEY)).toBe(JSON.stringify('user'));
    expect(s.todayAssignee).toBe('user');
  });

  /**
   * Memory must not hold what a reload would reject — the invariant
   * `theme.svelte.ts` states as "store and storage disagreeing across a
   * reload", here with an extra edge: `Partial<TasksFilterSettings>` admits an
   * explicit `undefined`, and `JSON.stringify` DROPS undefined-valued keys, so
   * an unsanitised merge leaves memory holding `undefined` while storage holds
   * no key at all. Both then read back as the codec's fallback — a value
   * neither side ever agreed to.
   */
  it('sanitises a filter patch on the way IN', async () => {
    const store = stubStorage();
    const s = await freshStore();

    // Task 7 clears a facet and casts an enum off a control's string value.
    s.setFilters({ assignee: undefined, mode: 'kanban' as TasksViewMode });

    expect(s.filters.assignee, "undefined is not a filter value; null is 'Everyone'").toBeNull();
    expect(s.filters.mode, 'an out-of-vocabulary value must not survive in memory').toBe('list');
    const reloaded = decodeTasksFilterSettings(JSON.parse(store.get(TASKS_FILTERS_KEY)!));
    expect(reloaded, 'what a reload yields must equal what memory holds').toEqual({ ...s.filters });
  });

  it('sanitises the Today assignee on the way IN', async () => {
    const store = stubStorage();
    const s = await freshStore();
    s.setTodayAssignee('agent' as 'user' | null);
    expect(s.todayAssignee, 'only the literal user narrows to Mine').toBeNull();
    expect(store.get(TODAY_ASSIGNEE_KEY)).toBe(JSON.stringify(null));
  });

  it('a broken localStorage still yields a working in-memory store', async () => {
    vi.stubGlobal('localStorage', { getItem: undefined, setItem: undefined });
    const s = await freshStore();
    expect(s.filters.mode).toBe('list');
    expect(() => s.setFilters({ mode: 'board' })).not.toThrow();
    expect(s.filters.mode).toBe('board');
  });
});

/**
 * Issue #4 in this store's shape: `setFilters` READS `this.filters` — the
 * spread that merges the patch — on the way to WRITING it, so without the
 * `untrack` any effect that calls it subscribes to the state it just wrote.
 * Worse than the theme case: the merge allocates a fresh object every time, so
 * the write always differs and the effect self-invalidates forever rather than
 * settling on an ===-equal second write.
 *
 * These build the store with `new TasksSettingsStore()`, NOT `freshStore()` —
 * see the note there. Both pins are falsified, each by deleting the `untrack`
 * from its own setter and re-running: `setFilters` dies inside `flushSync()`
 * with `effect_update_depth_exceeded`, and `setTodayAssignee` reports 2 runs
 * against 1 — that setter persists `this.todayAssignee` rather than `value`,
 * so it too reads what it just wrote, and settles at two runs only because its
 * second write is ===-equal.
 */
describe('TasksSettingsStore — the write paths must not subscribe their caller', () => {
  it('does not subscribe an effect that calls setFilters to what it wrote', () => {
    stubStorage();
    const s = new TasksSettingsStore();
    let runs = 0;
    const pulse = $state({ n: 0 });

    // The shape Task 7's Tasks page will have: a standing effect over some
    // OTHER state that pushes a filter through the store as a side effect.
    const stopRoot = $effect.root(() => {
      $effect(() => {
        runs++;
        void pulse.n;
        s.setFilters({ mode: 'board' });
      });
    });
    flushSync();
    expect(runs, 'writing must not invalidate the effect that wrote').toBe(1);

    // A control elsewhere on the page changes a filter. This effect only ever
    // WROTE `filters`, so it has no business waking up.
    s.setFilters({ view: 'all' });
    flushSync();
    expect(runs, 'a later filter change must not wake an effect that only wrote').toBe(1);

    // The untrack must not reach past the write path: what the effect really
    // reads still drives it.
    pulse.n++;
    flushSync();
    expect(runs, 'the effect must still re-run for its own dependency').toBe(2);

    stopRoot();
  });

  it('does not subscribe an effect that calls setTodayAssignee to what it wrote', () => {
    stubStorage();
    const s = new TasksSettingsStore();
    let runs = 0;

    const stopRoot = $effect.root(() => {
      $effect(() => {
        runs++;
        s.setTodayAssignee('user');
      });
    });
    flushSync();
    expect(runs).toBe(1);

    s.setTodayAssignee(null);
    flushSync();
    expect(runs, 'the Today toggle must not wake an effect that only wrote it').toBe(1);

    stopRoot();
  });

  it('still notifies readers that legitimately observe the settings', () => {
    // The fix must not over-reach. `filters` and `todayAssignee` are what the
    // Tasks and Today pages render from, so both stay reactive to a write from
    // anywhere — untracking a READ never suppresses a notification.
    stubStorage();
    const s = new TasksSettingsStore();
    const modes: string[] = [];
    const assignees: Array<string | null> = [];

    const stopRoot = $effect.root(() => {
      $effect(() => void modes.push(s.filters.mode));
      $effect(() => void assignees.push(s.todayAssignee));
    });
    flushSync();

    s.setFilters({ mode: 'board' });
    flushSync();
    s.setTodayAssignee('user');
    flushSync();

    expect(modes).toEqual(['list', 'board']);
    expect(assignees).toEqual([null, 'user']);
    stopRoot();
  });
});
