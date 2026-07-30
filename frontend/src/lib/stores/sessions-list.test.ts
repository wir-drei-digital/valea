import { describe, it, expect } from 'vitest';
import { SessionsListStore } from './sessions-list.svelte';
import type { ApiResult } from '../api/client';

describe('SessionsListStore.refresh', () => {
  it('populates sessions and flips loaded on success', async () => {
    const raw = [
      { id: 's1', kind: 'chat', status: 'running', live: true }
    ];
    const store = new SessionsListStore({
      listAgentSessions: async () => ({ ok: true, data: { sessions: raw } }) as ApiResult<any>
    });

    await store.refresh();

    expect(store.loaded).toBe(true);
    expect(store.sessions).toEqual(raw);
  });

  it('leaves sessions/loaded untouched on failure', async () => {
    const store = new SessionsListStore({
      listAgentSessions: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>
    });

    await store.refresh();

    expect(store.loaded).toBe(false);
    expect(store.sessions).toEqual([]);
  });
});

// Final review, I3. This store was route-local (disposed when `/chat`
// unmounted) until Task 7 promoted it to a shared singleton, at which point
// a workspace switch could leave the previous workspace's sessions on
// screen. `handleWorkspaceEvent` calling this is pinned in `icm.test.ts`.
describe('SessionsListStore.reset', () => {
  it('clears back to cold-start shape', async () => {
    const store = new SessionsListStore({
      listAgentSessions: async () =>
        ({
          ok: true,
          data: { sessions: [{ id: 's1', kind: 'chat', status: 'running', live: true }] }
        }) as ApiResult<any>
    });

    await store.refresh();
    expect(store.loaded).toBe(true);

    store.reset();

    expect(store.sessions).toEqual([]);
    expect(store.loaded).toBe(false);
  });

  it('is idempotent on an untouched store', () => {
    const store = new SessionsListStore({
      listAgentSessions: async () => ({ ok: true, data: { sessions: [] } }) as ApiResult<any>
    });

    store.reset();
    store.reset();

    expect(store.sessions).toEqual([]);
    expect(store.loaded).toBe(false);
  });
});

// tasks+schedules spec §Scheduled-session visibility: the all-sessions pane
// hides `kind: "scheduled"` runs behind its own toggle. The FLAT list stays
// unfiltered on purpose — it is also the open transcript's title index, and a
// scheduled run reached from its schedule's run history is exactly such a
// transcript (see `visibleSessions`' doc comment).
describe('SessionsListStore.visibleSessions', () => {
  const raw = [
    { id: 's1', kind: 'chat', status: 'ended', live: false },
    { id: 's2', kind: 'scheduled', status: 'ended', live: false },
    { id: 's3', status: 'ended', live: false }
  ];

  async function loaded() {
    const store = new SessionsListStore({
      listAgentSessions: async () => ({ ok: true, data: { sessions: raw } }) as ApiResult<any>
    });
    await store.refresh();
    return store;
  }

  it('hides scheduled runs by default, keeping every other kind (including none)', async () => {
    const store = await loaded();

    expect(store.includeScheduled).toBe(false);
    expect(store.visibleSessions.map((s) => s.id)).toEqual(['s1', 's3']);
    // The raw list — the title index — still has the scheduled run.
    expect(store.sessions.map((s) => s.id)).toEqual(['s1', 's2', 's3']);
    expect(store.scheduledCount).toBe(1);
  });

  it('reveals them when the toggle is on', async () => {
    const store = await loaded();
    store.includeScheduled = true;
    expect(store.visibleSessions.map((s) => s.id)).toEqual(['s1', 's2', 's3']);
  });
});
