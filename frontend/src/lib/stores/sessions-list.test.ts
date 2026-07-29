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
