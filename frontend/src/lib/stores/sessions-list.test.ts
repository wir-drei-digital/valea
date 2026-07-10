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
