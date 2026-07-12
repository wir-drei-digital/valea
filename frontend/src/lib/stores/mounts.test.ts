import { describe, it, expect, vi } from 'vitest';
import { MountsStore, mountsStore, wireMountsEvents } from './mounts.svelte';
import { icmStore } from './icm.svelte';
import type { ApiResult } from '../api/client';
import type { Channel } from 'phoenix';

type ListResult = ApiResult<{ mounts: any[] }>;
type SetEnabledResult = ApiResult<{ saved: boolean }>;
type CreateResult = ApiResult<{ relRoot: string }>;

function fakeApi(overrides: {
  listMounts?: () => Promise<ListResult>;
  setMountEnabled?: (name: string, enabled: boolean, generation: number) => Promise<SetEnabledResult>;
  createMount?: (name: string, description: string, generation: number) => Promise<CreateResult>;
}) {
  return {
    listMounts: overrides.listMounts ?? (async () => ({ ok: true, data: { mounts: [] } }) as ListResult),
    setMountEnabled:
      overrides.setMountEnabled ?? (async () => ({ ok: true, data: { saved: true } }) as SetEnabledResult),
    createMount:
      overrides.createMount ?? (async () => ({ ok: true, data: { relRoot: 'mounts/x' } }) as CreateResult)
  };
}

describe('MountsStore.refresh', () => {
  it('populates mounts and flips loaded on success', async () => {
    const rawMounts = [
      {
        name: 'primary',
        title: 'Primary',
        description: 'The default mount',
        relRoot: '',
        enabled: true,
        degraded: null
      },
      {
        name: 'clients',
        title: 'Clients',
        description: 'Client-facing docs',
        relRoot: 'mounts/clients',
        enabled: false,
        degraded: 'manifest_missing'
      }
    ];
    const store = new MountsStore(fakeApi({ listMounts: async () => ({ ok: true, data: { mounts: rawMounts } }) }) as never);

    await store.refresh();

    expect(store.loaded).toBe(true);
    expect(store.mounts).toEqual(rawMounts);
  });

  it('leaves mounts/loaded untouched on failure', async () => {
    const store = new MountsStore(fakeApi({ listMounts: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never);

    await store.refresh();

    expect(store.loaded).toBe(false);
    expect(store.mounts).toEqual([]);
  });
});

describe('MountsStore.setEnabled', () => {
  it('threads name/enabled/generation to the api and refreshes on success', async () => {
    const setMountEnabled = vi.fn(async () => ({ ok: true, data: { saved: true } }) as SetEnabledResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ setMountEnabled, listMounts }) as never);

    const result = await store.setEnabled('clients', false, 5);

    expect(setMountEnabled).toHaveBeenCalledWith('clients', false, 5);
    expect(listMounts).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const setMountEnabled = vi.fn(async () => ({ ok: false, error: 'workspace_changed' }) as SetEnabledResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ setMountEnabled, listMounts }) as never);

    const result = await store.setEnabled('clients', true, 1);

    expect(result).toEqual({ ok: false, error: 'workspace_changed' });
    expect(listMounts).not.toHaveBeenCalled();
  });
});

describe('MountsStore.create', () => {
  it('threads name/description/generation and returns relRoot on success', async () => {
    const createMount = vi.fn(async () => ({ ok: true, data: { relRoot: 'mounts/new-mount' } }) as CreateResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ createMount, listMounts }) as never);

    const result = await store.create('new-mount', 'A new mount', 9);

    expect(createMount).toHaveBeenCalledWith('new-mount', 'A new mount', 9);
    expect(listMounts).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true, relRoot: 'mounts/new-mount' });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const createMount = vi.fn(async () => ({ ok: false, error: 'already_exists' }) as CreateResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ createMount, listMounts }) as never);

    const result = await store.create('clients', '', 2);

    expect(result).toEqual({ ok: false, error: 'already_exists' });
    expect(listMounts).not.toHaveBeenCalled();
  });
});

describe('MountsStore.handleMountsChanged', () => {
  it('refetches mounts AND triggers the icm store refetch', async () => {
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ listMounts }) as never);
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);

    await store.handleMountsChanged();

    expect(listMounts).toHaveBeenCalledTimes(1);
    expect(store.loaded).toBe(true);
    expect(icmRefetch).toHaveBeenCalledTimes(1);

    icmRefetch.mockRestore();
  });
});

// `mountsEventsWired` is a module-level latch (see `mounts.svelte.ts`), so it
// can only be meaningfully exercised ONCE per test file — same convention as
// `wireQueueEvents`'s test in `queue.test.ts`.
describe('wireMountsEvents', () => {
  it('attaches mounts_changed to the first channel only, and calls handleMountsChanged on that push', () => {
    const handleMountsChanged = vi.spyOn(mountsStore, 'handleMountsChanged').mockResolvedValue(undefined);
    const handlersA: Record<string, (payload: unknown) => void> = {};
    const channelA = { on: (event: string, cb: (payload: unknown) => void) => (handlersA[event] = cb) } as unknown as Channel;
    const handlersB: Record<string, (payload: unknown) => void> = {};
    const channelB = { on: (event: string, cb: (payload: unknown) => void) => (handlersB[event] = cb) } as unknown as Channel;

    wireMountsEvents(channelA);
    wireMountsEvents(channelB); // idempotent no-op: never attaches to a second channel

    expect(handlersA['mounts_changed']).toBeTypeOf('function');
    expect(handlersB['mounts_changed']).toBeUndefined();

    handlersA['mounts_changed']({});

    expect(handleMountsChanged).toHaveBeenCalledTimes(1);
    handleMountsChanged.mockRestore();
  });
});
