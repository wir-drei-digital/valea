import { describe, it, expect, vi } from 'vitest';
import { RecentSessionsStore, recentSessionsStore, wireRecentSessionsEvents } from './recent-sessions.svelte';
import { SESSIONS_PER_GROUP } from '../components/shell/icm-projects';
import type { ApiResult } from '../api/client';
import type { Channel } from 'phoenix';

type RecentResult = ApiResult<{ groups: unknown[] }>;

function fakeApi(overrides: { listRecentSessionsByIcm?: (limit?: number) => Promise<RecentResult> }) {
  return {
    listRecentSessionsByIcm:
      overrides.listRecentSessionsByIcm ?? (async () => ({ ok: true, data: { groups: [] } }) as RecentResult)
  };
}

describe('RecentSessionsStore.refresh', () => {
  it('populates groups (server order preserved) and flips loaded on success', async () => {
    const raw = [
      {
        mountKey: 'coaching',
        icmName: 'Coaching',
        sessions: [
          {
            id: 's1',
            kind: 'chat',
            title: 'Session 1',
            workflow: null,
            runId: null,
            startedAt: '2026-07-14T10:00:00Z',
            status: 'running',
            live: true
          },
          {
            id: 's2',
            kind: 'chat',
            title: 'Session 2',
            workflow: null,
            runId: null,
            startedAt: '2026-07-10T10:00:00Z',
            status: 'ended',
            live: false
          }
        ]
      },
      { mountKey: 'clients', icmName: 'Clients', sessions: [] }
    ];
    const store = new RecentSessionsStore(
      fakeApi({ listRecentSessionsByIcm: async () => ({ ok: true, data: { groups: raw } }) as RecentResult })
    );

    await store.refresh();

    expect(store.loaded).toBe(true);
    expect(store.groups).toEqual(raw);
    expect(store.sessionsFor('coaching')).toEqual(raw[0].sessions);
    expect(store.sessionsFor('clients')).toEqual([]);
    expect(store.sessionsFor('unknown-mount')).toEqual([]);
  });

  it('leaves groups/loaded untouched on failure', async () => {
    const store = new RecentSessionsStore(
      fakeApi({ listRecentSessionsByIcm: async () => ({ ok: false, error: 'workspace_not_open' }) as RecentResult })
    );

    await store.refresh();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });

  it('requests SESSIONS_PER_GROUP + 1 sessions per group — the extra one is a pure overflow signal (Finding 1): the backend truncates server-side, so `orderGroups` can only ever see >5 to set hasMore if the store asks for 6', async () => {
    const listRecentSessionsByIcm = vi.fn(async () => ({ ok: true, data: { groups: [] } }) as RecentResult);
    const store = new RecentSessionsStore(fakeApi({ listRecentSessionsByIcm }));

    await store.refresh();

    expect(listRecentSessionsByIcm).toHaveBeenCalledWith(SESSIONS_PER_GROUP + 1);
  });
});

describe('RecentSessionsStore.reset', () => {
  it('clears groups and loaded back to cold-start, so sessionsFor no longer returns a previously-populated ICM\'s stale sessions', async () => {
    const raw = [
      { mountKey: 'coaching', icmName: 'Coaching', sessions: [{ id: 's1', kind: 'chat', title: 'Session 1', workflow: null, runId: null, startedAt: '2026-07-14T10:00:00Z', status: 'running', live: true }] }
    ];
    const store = new RecentSessionsStore(
      fakeApi({ listRecentSessionsByIcm: async () => ({ ok: true, data: { groups: raw } }) as RecentResult })
    );

    await store.refresh();
    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
    expect(store.sessionsFor('coaching')).toEqual([]);
  });

  it('is safe to call before any refresh has resolved', () => {
    const store = new RecentSessionsStore(fakeApi({}));

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });
});

// `recentSessionsEventsWired` is a module-level latch (see
// `recent-sessions.svelte.ts`), so it can only be meaningfully exercised ONCE
// per test file — same convention as `wireMountsEvents`'s test in `mounts.test.ts`.
describe('wireRecentSessionsEvents', () => {
  it('attaches mounts_changed to the first channel only, and refreshes on that push', () => {
    const refresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);
    const handlersA: Record<string, (payload: unknown) => void> = {};
    const channelA = {
      on: (event: string, cb: (payload: unknown) => void) => (handlersA[event] = cb)
    } as unknown as Channel;
    const handlersB: Record<string, (payload: unknown) => void> = {};
    const channelB = {
      on: (event: string, cb: (payload: unknown) => void) => (handlersB[event] = cb)
    } as unknown as Channel;

    wireRecentSessionsEvents(channelA);
    wireRecentSessionsEvents(channelB); // idempotent no-op: never attaches to a second channel

    expect(handlersA['mounts_changed']).toBeTypeOf('function');
    expect(handlersB['mounts_changed']).toBeUndefined();

    handlersA['mounts_changed']({});

    expect(refresh).toHaveBeenCalledTimes(1);
    refresh.mockRestore();
  });
});
