import { beforeEach, describe, expect, it } from 'vitest';
import { TasksStore, normalizeSchedule, normalizeScheduleRun, normalizeTaskIcm } from './store.svelte';
import { workspaceStore } from '../stores/workspace.svelte';

beforeEach(() => {
  workspaceStore.id = 'ws-1';
  workspaceStore.generation = 7;
});

type Call = { fn: string; args: unknown[] };

/** Records every call in order and returns canned ApiResults — the `Pick<Api>` fake convention (`calendar.test.ts`). */
function fakeApi(overrides: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const ok = (data: unknown) => async () => ({ ok: true as const, data });
  const record =
    (fn: string, impl: (...args: unknown[]) => Promise<unknown>) =>
    async (...args: unknown[]) => {
      calls.push({ fn, args });
      return impl(...args);
    };

  const base: Record<string, (...args: unknown[]) => Promise<unknown>> = {
    listTasks: ok({ icms: [] }),
    createTask: ok({ task: {} }),
    mutateTask: ok({ task: {} }),
    archiveDone: ok({ archived: 0, pruned: 0, icms: [] }),
    listSchedules: ok({ icms: [], schedulerPaused: 'off' }),
    createSchedule: ok({ schedule: {}, disposition: 'executable', reason: null }),
    mutateSchedule: ok({ schedule: {}, disposition: 'executable', reason: null }),
    deleteSchedule: ok({ deleted: true }),
    runScheduleNow: ok({ runId: 'run-1' }),
    scheduleRunHistory: ok({ runs: [] }),
    setSchedulerPaused: ok({ schedulerPaused: 'on' }),
    ...(overrides as Record<string, (...args: unknown[]) => Promise<unknown>>)
  };

  const wrapped = Object.fromEntries(Object.entries(base).map(([fn, impl]) => [fn, record(fn, impl)]));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return { api: wrapped as any, calls };
}

const TASK_ROWS = [
  {
    mountKey: 'primary',
    icmName: 'Mara Lindt Coaching',
    status: 'ok',
    tasks: [
      { id: 't-1', title: 'Send the offer', status: 'open', today: true, created_by: 'agent', colour: 'green' },
      { id: 't-1', title: 'Duplicate id', status: 'open' }
    ]
  },
  { mountKey: 'clients', icmName: 'Clients', status: 'unreadable', tasks: [] }
];

const SCHEDULE_ROWS = [
  {
    mountKey: 'primary',
    icmName: 'Mara Lindt Coaching',
    status: 'ok',
    schedules: [
      {
        id: 's-1',
        title: 'Morning brief',
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
      }
    ]
  }
];

describe('normalizers', () => {
  it('reads the wire’s snake_case keys and keeps unknown task fields', () => {
    const icm = normalizeTaskIcm(TASK_ROWS[0]);
    expect(icm.mountKey).toBe('primary');
    expect(icm.icmName).toBe('Mara Lindt Coaching');
    expect(icm.status).toBe('ok');
    expect(icm.tasks[0].createdBy).toBe('agent');
    expect(icm.tasks[0].raw.colour).toBe('green');
  });

  it('accepts the camelCase spelling as a fallback (the cockpit normalizer’s stance)', () => {
    const icm = normalizeTaskIcm({ mount_key: 'primary', icm_name: 'Studio', status: 'ok', tasks: [] });
    expect(icm.mountKey).toBe('primary');
    expect(icm.icmName).toBe('Studio');

    const entry = normalizeSchedule({ id: 's', payloadKind: 'command', nextFire: 'x', registeredRecently: true });
    expect(entry.payloadKind).toBe('command');
    expect(entry.nextFire).toBe('x');
    expect(entry.registeredRecently).toBe(true);
  });

  it('defaults an unrecognized ledger status to unreadable rather than pretending it is ok', () => {
    expect(normalizeTaskIcm({ status: 'weird', tasks: [] }).status).toBe('unreadable');
    expect(normalizeTaskIcm({ tasks: [] }).status).toBe('unreadable');
  });

  it('defaults an unrecognized disposition to not_executable — fail closed', () => {
    expect(normalizeSchedule({ id: 's', disposition: 'nonsense' }).disposition).toBe('not_executable');
    expect(normalizeSchedule({ id: 's' }).disposition).toBe('not_executable');
  });

  it('treats `paused`/`catchup`/`registered_recently` as set only for a real JSON true', () => {
    const entry = normalizeSchedule({ id: 's', paused: 'yes', catchup: 1, registered_recently: 'true' });
    expect(entry.paused).toBe(false);
    expect(entry.catchup).toBe(false);
    expect(entry.registeredRecently).toBe(false);
  });

  it('normalizes a run record, nulling a wrong-typed duration', () => {
    const run = normalizeScheduleRun({
      id: 'r',
      fired_at: '2026-07-30T05:30:00Z',
      duration_ms: 'fast',
      session_id: 'sess-1',
      coalesced_count: 2
    });
    expect(run.firedAt).toBe('2026-07-30T05:30:00Z');
    expect(run.durationMs).toBeNull();
    expect(run.sessionId).toBe('sess-1');
    expect(run.coalescedCount).toBe(2);
  });

  it('drops non-map array items instead of rendering them', () => {
    const icm = normalizeTaskIcm({ mount_key: 'p', icm_name: 'P', status: 'ok', tasks: ['nope', null, { id: 't' }] });
    expect(icm.tasks).toHaveLength(1);
    expect(icm.tasks[0].id).toBe('t');
  });
});

describe('refresh', () => {
  it('passes the workspace generation on every read', async () => {
    const { api, calls } = fakeApi({
      listTasks: async () => ({ ok: true as const, data: { icms: TASK_ROWS } }),
      listSchedules: async () => ({ ok: true as const, data: { icms: SCHEDULE_ROWS, schedulerPaused: 'on' } })
    });
    const store = new TasksStore(api);

    await store.refresh();

    expect(calls.map((c) => c.fn).sort()).toEqual(['listSchedules', 'listTasks']);
    expect(calls[0].args[0]).toEqual({ generation: 7 });
    expect(store.taskIcms).toHaveLength(2);
    expect(store.scheduleIcms[0].schedules[0].cadence).toBe('30 7 * * 1-5');
    expect(store.schedulerPaused).toBe('on');
    expect(store.loaded).toBe(true);
    expect(store.failed).toBe(false);
  });

  it('reads the TRI-state kill switch, defaulting an unexpected value to off', async () => {
    for (const [wire, expected] of [
      ['on', 'on'],
      ['off', 'off'],
      ['unreadable', 'unreadable'],
      ['nonsense', 'off']
    ] as const) {
      const { api } = fakeApi({
        listSchedules: async () => ({ ok: true as const, data: { icms: [], schedulerPaused: wire } })
      });
      const store = new TasksStore(api);
      await store.refreshSchedules();
      expect(store.schedulerPaused).toBe(expected);
    }
  });

  it('accepts the snake spelling of the kill switch too', async () => {
    const { api } = fakeApi({
      listSchedules: async () => ({ ok: true as const, data: { icms: [], scheduler_paused: 'unreadable' } })
    });
    const store = new TasksStore(api);
    await store.refreshSchedules();
    expect(store.schedulerPaused).toBe('unreadable');
  });

  it('marks failed only on a FIRST load, keeping the last good payload afterwards', async () => {
    let fail = true;
    const { api } = fakeApi({
      listTasks: async () =>
        fail ? { ok: false as const, error: 'workspace_not_open' } : { ok: true as const, data: { icms: TASK_ROWS } }
    });
    const store = new TasksStore(api);

    await store.refreshTasks();
    expect(store.failed).toBe(true);
    expect(store.loaded).toBe(false);

    fail = false;
    await store.refreshTasks();
    expect(store.failed).toBe(false);
    expect(store.loaded).toBe(true);

    fail = true;
    await store.refreshTasks();
    // A failed BACKGROUND refresh keeps the rows on screen.
    expect(store.failed).toBe(false);
    expect(store.taskIcms).toHaveLength(2);
  });

  it('reset clears back to cold-start shape', async () => {
    const { api } = fakeApi({
      listTasks: async () => ({ ok: true as const, data: { icms: TASK_ROWS } }),
      listSchedules: async () => ({ ok: true as const, data: { icms: SCHEDULE_ROWS, schedulerPaused: 'on' } })
    });
    const store = new TasksStore(api);
    await store.refresh();

    store.reset();

    expect(store.taskIcms).toEqual([]);
    expect(store.scheduleIcms).toEqual([]);
    expect(store.schedulerPaused).toBe('off');
    expect(store.loaded).toBe(false);
  });
});

describe('task mutations', () => {
  it('the row checkbox fires mutate_task with status done, then re-lists', async () => {
    const { api, calls } = fakeApi({
      listTasks: async () => ({ ok: true as const, data: { icms: TASK_ROWS } })
    });
    const store = new TasksStore(api);
    await store.refreshTasks();

    const outcome = await store.setTaskStatus('primary', 't-1', 'done');

    expect(outcome).toEqual({ ok: true });
    const mutate = calls.find((c) => c.fn === 'mutateTask');
    expect(mutate?.args[0]).toEqual({
      mountKey: 'primary',
      taskId: 't-1',
      patch: { status: 'done' },
      generation: 7
    });
    // A re-list follows, so the file stays the authority.
    expect(calls.filter((c) => c.fn === 'listTasks')).toHaveLength(2);
  });

  it('patches the row optimistically — only the FIRST carrier of a duplicate id, and unknown fields survive', async () => {
    // No re-list answer, so the optimistic patch is what the tab renders.
    const { api } = fakeApi({
      listTasks: async () => ({ ok: true as const, data: { icms: TASK_ROWS } }),
      mutateTask: async () => new Promise(() => {}) as Promise<never>
    });
    const store = new TasksStore(api);
    await store.refreshTasks();

    void store.patchTask('primary', 't-1', { status: 'done' });
    await Promise.resolve();

    const tasks = store.taskIcms[0].tasks;
    expect(tasks[0].status).toBe('done');
    expect(tasks[0].raw.colour).toBe('green');
    // "First occurrence wins for addressing" — the duplicate is untouched.
    expect(tasks[1].status).toBe('open');
  });

  it('surfaces a mutate failure as its backend code', async () => {
    const { api } = fakeApi({ mutateTask: async () => ({ ok: false as const, error: 'conflict' }) });
    const store = new TasksStore(api);
    expect(await store.setTaskStatus('primary', 't-1', 'done')).toEqual({ ok: false, error: 'conflict' });
  });

  it('quick-add passes the file’s own field names through verbatim', async () => {
    const { api, calls } = fakeApi();
    const store = new TasksStore(api);

    await store.createTask('primary', { title: 'New task', assignee: 'agent', today: true });

    expect(calls.find((c) => c.fn === 'createTask')?.args[0]).toEqual({
      mountKey: 'primary',
      fields: { title: 'New task', assignee: 'agent', today: true },
      generation: 7
    });
  });

  it('Clear done targets one ICM, or omits mountKey for all of them', async () => {
    const { api, calls } = fakeApi();
    const store = new TasksStore(api);

    await store.clearDone('primary');
    await store.clearDone(null);

    const [one, all] = calls.filter((c) => c.fn === 'archiveDone');
    expect(one.args[0]).toEqual({ mountKey: 'primary', generation: 7 });
    expect(all.args[0]).toEqual({ generation: 7 });
  });
});

describe('schedule mutations', () => {
  it('the pause toggle writes the file field and reports the fresh disposition', async () => {
    const { api, calls } = fakeApi({
      listSchedules: async () => ({ ok: true as const, data: { icms: SCHEDULE_ROWS, schedulerPaused: 'off' } }),
      mutateSchedule: async () => ({
        ok: true as const,
        data: { schedule: { id: 's-1', paused: true }, disposition: 'paused', reason: null }
      })
    });
    const store = new TasksStore(api);
    await store.refreshSchedules();

    const outcome = await store.setSchedulePaused('primary', 's-1', true);

    expect(outcome).toEqual({ ok: true, disposition: 'paused', reason: null });
    expect(calls.find((c) => c.fn === 'mutateSchedule')?.args[0]).toEqual({
      mountKey: 'primary',
      scheduleId: 's-1',
      patch: { paused: true },
      generation: 7
    });
  });

  it('a malformed pause attempt lands as not_executable — the row must not keep saying "Active"', async () => {
    const { api } = fakeApi({
      listSchedules: async () => ({ ok: true as const, data: { icms: SCHEDULE_ROWS, schedulerPaused: 'off' } }),
      mutateSchedule: async () => ({
        ok: true as const,
        data: {
          schedule: { id: 's-1' },
          disposition: 'not_executable',
          reason: '`paused` is not a boolean'
        }
      })
    });
    const store = new TasksStore(api);
    await store.refreshSchedules();

    const outcome = await store.patchSchedule('primary', 's-1', { paused: 'yes' });

    expect(outcome).toEqual({ ok: true, disposition: 'not_executable', reason: '`paused` is not a boolean' });
    // The re-list answers the same rows, so the local patch is what proves the
    // verdict reached the row without waiting for a fresh list.
    expect(store.scheduleIcms[0].schedules[0].disposition).toBe('executable');
  });

  it('keeps the row’s previous verdict when the entry vanished under the write (null/null)', async () => {
    const { api } = fakeApi({
      listSchedules: async () => ({ ok: true as const, data: { icms: SCHEDULE_ROWS, schedulerPaused: 'off' } }),
      mutateSchedule: async () => ({
        ok: true as const,
        data: { schedule: { id: 's-1' }, disposition: null, reason: null }
      })
    });
    const store = new TasksStore(api);
    await store.refreshSchedules();

    expect(await store.patchSchedule('primary', 's-1', { paused: true })).toEqual({
      ok: true,
      disposition: null,
      reason: null
    });
    expect(store.scheduleIcms[0].schedules[0].disposition).toBe('executable');
  });

  it('create surfaces the write’s own disposition without a second round trip', async () => {
    const { api, calls } = fakeApi({
      createSchedule: async () => ({
        ok: true as const,
        data: { schedule: { id: 's-9' }, disposition: 'not_executable', reason: 'invalid cron' }
      })
    });
    const store = new TasksStore(api);

    expect(await store.createSchedule('primary', { title: 'Nightly', cron: '30 25 * * *' })).toEqual({
      ok: true,
      disposition: 'not_executable',
      reason: 'invalid cron'
    });
    expect(calls.find((c) => c.fn === 'createSchedule')?.args[0]).toEqual({
      mountKey: 'primary',
      fields: { title: 'Nightly', cron: '30 25 * * *' },
      generation: 7
    });
  });

  it('run now answers the run id, and maps a refusal to its code', async () => {
    const { api, calls } = fakeApi();
    const store = new TasksStore(api);
    expect(await store.runNow('primary', 's-1')).toEqual({ ok: true, runId: 'run-1' });
    expect(calls.find((c) => c.fn === 'runScheduleNow')?.args[0]).toEqual({
      mountKey: 'primary',
      scheduleId: 's-1',
      generation: 7
    });

    const refused = fakeApi({ runScheduleNow: async () => ({ ok: false as const, error: 'not_executable' }) });
    expect(await new TasksStore(refused.api).runNow('primary', 's-1')).toEqual({
      ok: false,
      error: 'not_executable'
    });
  });

  it('accepts the snake spelling of run_id', async () => {
    const { api } = fakeApi({ runScheduleNow: async () => ({ ok: true as const, data: { run_id: 'r-7' } }) });
    expect(await new TasksStore(api).runNow('primary', 's-1')).toEqual({ ok: true, runId: 'r-7' });
  });

  it('run history normalizes rows and passes an explicit limit', async () => {
    const { api, calls } = fakeApi({
      scheduleRunHistory: async () => ({
        ok: true as const,
        data: { runs: [{ id: 'r-1', fired_at: 'x', duration_ms: 10, coalesced_count: 1 }] }
      })
    });
    const store = new TasksStore(api);

    const result = await store.runHistory('primary', 's-1', 5);

    expect(result).toEqual({ ok: true, runs: [expect.objectContaining({ id: 'r-1', durationMs: 10 })] });
    expect(calls.find((c) => c.fn === 'scheduleRunHistory')?.args[0]).toEqual({
      mountKey: 'primary',
      scheduleId: 's-1',
      limit: 5,
      generation: 7
    });

    await store.runHistory('primary', 's-1');
    expect(calls.filter((c) => c.fn === 'scheduleRunHistory')[1].args[0]).toEqual({
      mountKey: 'primary',
      scheduleId: 's-1',
      generation: 7
    });
  });

  it('delete re-lists on success and reports the code on failure', async () => {
    const { api, calls } = fakeApi();
    const store = new TasksStore(api);
    expect(await store.deleteSchedule('primary', 's-1')).toEqual({ ok: true });
    expect(calls.filter((c) => c.fn === 'listSchedules')).toHaveLength(1);

    const failing = fakeApi({ deleteSchedule: async () => ({ ok: false as const, error: 'not_found' }) });
    expect(await new TasksStore(failing.api).deleteSchedule('primary', 's-1')).toEqual({
      ok: false,
      error: 'not_found'
    });
  });

  it('Pause-all takes the state READ BACK from the file, unreadable included', async () => {
    const { api, calls } = fakeApi();
    const store = new TasksStore(api);

    expect(await store.setSchedulerPaused(true)).toEqual({ ok: true });
    expect(calls.find((c) => c.fn === 'setSchedulerPaused')?.args[0]).toEqual({ paused: true, generation: 7 });
    expect(store.schedulerPaused).toBe('on');

    const unreadable = fakeApi({
      setSchedulerPaused: async () => ({ ok: true as const, data: { schedulerPaused: 'unreadable' } })
    });
    const other = new TasksStore(unreadable.api);
    await other.setSchedulerPaused(false);
    expect(other.schedulerPaused).toBe('unreadable');
  });

  it('a refused Pause-all leaves the local state alone', async () => {
    const { api } = fakeApi({
      setSchedulerPaused: async () => ({ ok: false as const, error: 'config_unreadable' })
    });
    const store = new TasksStore(api);
    expect(await store.setSchedulerPaused(true)).toEqual({ ok: false, error: 'config_unreadable' });
    expect(store.schedulerPaused).toBe('off');
  });
});
