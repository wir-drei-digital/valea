import { describe, it, expect, vi } from 'vitest';
import { QueueStore, queueStore, wireQueueEvents } from './queue.svelte';
import { workspaceStore } from './workspace.svelte';
import type { ApiResult } from '../api/client';
import type { Channel } from 'phoenix';

type ListResult = ApiResult<{ items: any[] }>;
type DetailResult = ApiResult<{ item: any; revision: string }>;
type ApproveResult = ApiResult<{ draftPath: string }>;
type RejectResult = ApiResult<{ rejected: boolean }>;

function fakeApi(overrides: {
  listQueueItems?: () => Promise<ListResult>;
  getQueueItem?: (runId: string) => Promise<DetailResult>;
  approveQueueItem?: (runId: string, revision: string, generation: number) => Promise<ApproveResult>;
  rejectQueueItem?: (runId: string, revision: string, generation: number) => Promise<RejectResult>;
}) {
  return {
    listQueueItems: overrides.listQueueItems ?? (async () => ({ ok: true, data: { items: [] } }) as ListResult),
    getQueueItem:
      overrides.getQueueItem ??
      (async () => ({ ok: true, data: { item: {}, revision: 'r0' } }) as DetailResult),
    approveQueueItem:
      overrides.approveQueueItem ??
      (async () => ({ ok: true, data: { draftPath: '/draft' } }) as ApproveResult),
    rejectQueueItem:
      overrides.rejectQueueItem ?? (async () => ({ ok: true, data: { rejected: true } }) as RejectResult)
  };
}

describe('QueueStore.refetch', () => {
  it('populates items and flips loaded on success', async () => {
    const rawItems = [
      {
        runId: 'r1',
        title: 'Draft reply',
        summary: 'summary',
        kind: 'draft',
        riskLevel: 'low',
        createdAt: '2026-07-10T00:00:00Z',
        workflow: 'wf',
        valid: true
      }
    ];
    const store = new QueueStore(fakeApi({ listQueueItems: async () => ({ ok: true, data: { items: rawItems } }) }) as never);

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.items).toEqual(rawItems);
  });

  it('leaves items/loaded untouched on failure', async () => {
    const store = new QueueStore(fakeApi({ listQueueItems: async () => ({ ok: false, error: 'unknown_error' }) }) as never);

    await store.refetch();

    expect(store.loaded).toBe(false);
    expect(store.items).toEqual([]);
  });
});

describe('QueueStore.detail', () => {
  it('passes through getQueueItem', async () => {
    const getQueueItem = vi.fn(async () => ({ ok: true, data: { item: { schema: 'x' }, revision: 'rev1' } }) as DetailResult);
    const store = new QueueStore(fakeApi({ getQueueItem }) as never);

    const result = await store.detail('run1');

    expect(getQueueItem).toHaveBeenCalledWith('run1');
    expect(result).toEqual({ ok: true, data: { item: { schema: 'x' }, revision: 'rev1' } });
  });
});

describe('QueueStore.approve / reject', () => {
  it('approve passes workspaceStore.generation and refetches on success', async () => {
    workspaceStore.generation = 7;
    const approveQueueItem = vi.fn(async () => ({ ok: true, data: { draftPath: '/x' } }) as ApproveResult);
    const listQueueItems = vi.fn(async () => ({ ok: true, data: { items: [] } }) as ListResult);
    const store = new QueueStore(fakeApi({ approveQueueItem, listQueueItems }) as never);

    const result = await store.approve('run1', 'rev1');

    expect(approveQueueItem).toHaveBeenCalledWith('run1', 'rev1', 7);
    expect(listQueueItems).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('approve does not refetch and surfaces the error on failure', async () => {
    workspaceStore.generation = 3;
    const approveQueueItem = vi.fn(async () => ({ ok: false, error: 'stale_revision' }) as ApproveResult);
    const listQueueItems = vi.fn(async () => ({ ok: true, data: { items: [] } }) as ListResult);
    const store = new QueueStore(fakeApi({ approveQueueItem, listQueueItems }) as never);

    const result = await store.approve('run1', 'rev1');

    expect(result).toEqual({ ok: false, error: 'stale_revision' });
    expect(listQueueItems).not.toHaveBeenCalled();
  });

  it('reject passes workspaceStore.generation and refetches on success', async () => {
    workspaceStore.generation = 12;
    const rejectQueueItem = vi.fn(async () => ({ ok: true, data: { rejected: true } }) as RejectResult);
    const listQueueItems = vi.fn(async () => ({ ok: true, data: { items: [] } }) as ListResult);
    const store = new QueueStore(fakeApi({ rejectQueueItem, listQueueItems }) as never);

    const result = await store.reject('run2', 'rev2');

    expect(rejectQueueItem).toHaveBeenCalledWith('run2', 'rev2', 12);
    expect(listQueueItems).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('falls back to generation 0 when the workspace has no generation yet', async () => {
    workspaceStore.generation = null;
    const approveQueueItem = vi.fn(async () => ({ ok: true, data: { draftPath: '/x' } }) as ApproveResult);
    const store = new QueueStore(fakeApi({ approveQueueItem }) as never);

    await store.approve('run1', 'rev1');

    expect(approveQueueItem).toHaveBeenCalledWith('run1', 'rev1', 0);
  });
});

// `queueEventsWired` is a module-level latch (see `queue.svelte.ts`), so it
// can only be meaningfully exercised ONCE per test file — this is the single
// test in the file that calls `wireQueueEvents`, keeping the "first call
// wins" assertion deterministic instead of depending on test execution order.
describe('wireQueueEvents', () => {
  it('attaches queue_changed to the first channel only, and refetches on that push', () => {
    const refetch = vi.spyOn(queueStore, 'refetch').mockResolvedValue(undefined);
    const handlersA: Record<string, (payload: unknown) => void> = {};
    const channelA = { on: (event: string, cb: (payload: unknown) => void) => (handlersA[event] = cb) } as unknown as Channel;
    const handlersB: Record<string, (payload: unknown) => void> = {};
    const channelB = { on: (event: string, cb: (payload: unknown) => void) => (handlersB[event] = cb) } as unknown as Channel;

    wireQueueEvents(channelA);
    wireQueueEvents(channelB); // idempotent no-op: never attaches to a second channel

    expect(handlersA['queue_changed']).toBeTypeOf('function');
    expect(handlersB['queue_changed']).toBeUndefined();

    handlersA['queue_changed']({});

    expect(refetch).toHaveBeenCalledTimes(1);
    refetch.mockRestore();
  });
});
