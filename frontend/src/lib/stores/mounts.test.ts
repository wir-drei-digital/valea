import { describe, it, expect, vi } from 'vitest';
import {
  MountsStore,
  mountsStore,
  wireMountsEvents,
  declareMountErrorMessage,
  undeclareMountErrorMessage
} from './mounts.svelte';
import { icmStore } from './icm.svelte';
import type { ApiResult } from '../api/client';
import type { Channel } from 'phoenix';

type ListResult = ApiResult<{ mounts: any[] }>;
type SetEnabledResult = ApiResult<{ saved: boolean }>;
type CreateResult = ApiResult<{ relRoot: string }>;
type DeclareResult = ApiResult<{ declared: boolean }>;
type UndeclareResult = ApiResult<{ undeclared: boolean }>;
type DoctorResult = ApiResult<{ ok: boolean; checks: unknown[] }>;

function fakeApi(overrides: {
  listMounts?: () => Promise<ListResult>;
  setMountEnabled?: (name: string, enabled: boolean, generation: number) => Promise<SetEnabledResult>;
  createMount?: (name: string, description: string, generation: number) => Promise<CreateResult>;
  declareMount?: (name: string, ref: string, generation: number) => Promise<DeclareResult>;
  undeclareMount?: (name: string, generation: number) => Promise<UndeclareResult>;
  mountsDoctor?: (generation: number) => Promise<DoctorResult>;
}) {
  return {
    listMounts: overrides.listMounts ?? (async () => ({ ok: true, data: { mounts: [] } }) as ListResult),
    setMountEnabled:
      overrides.setMountEnabled ?? (async () => ({ ok: true, data: { saved: true } }) as SetEnabledResult),
    createMount:
      overrides.createMount ?? (async () => ({ ok: true, data: { relRoot: 'mounts/x' } }) as CreateResult),
    declareMount:
      overrides.declareMount ?? (async () => ({ ok: true, data: { declared: true } }) as DeclareResult),
    undeclareMount:
      overrides.undeclareMount ?? (async () => ({ ok: true, data: { undeclared: true } }) as UndeclareResult),
    mountsDoctor:
      overrides.mountsDoctor ?? (async () => ({ ok: true, data: { ok: true, checks: [] } }) as DoctorResult)
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

describe('MountsStore.declare', () => {
  it('threads name/ref/generation to the api and refreshes on success (A2-T9)', async () => {
    const declareMount = vi.fn(async () => ({ ok: true, data: { declared: true } }) as DeclareResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ declareMount, listMounts }) as never);

    const result = await store.declare('client-notes', '/Users/mara/Documents/Client Notes', 3);

    expect(declareMount).toHaveBeenCalledWith('client-notes', '/Users/mara/Documents/Client Notes', 3);
    expect(listMounts).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const declareMount = vi.fn(async () => ({ ok: false, error: 'inside_workspace' }) as DeclareResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ declareMount, listMounts }) as never);

    const result = await store.declare('client-notes', '/workspace/mounts/primary', 3);

    expect(result).toEqual({ ok: false, error: 'inside_workspace' });
    expect(listMounts).not.toHaveBeenCalled();
  });
});

describe('MountsStore.undeclare', () => {
  it('threads name/generation to the api and refreshes on success (A2-T9)', async () => {
    const undeclareMount = vi.fn(async () => ({ ok: true, data: { undeclared: true } }) as UndeclareResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ undeclareMount, listMounts }) as never);

    const result = await store.undeclare('client-notes', 6);

    expect(undeclareMount).toHaveBeenCalledWith('client-notes', 6);
    expect(listMounts).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const undeclareMount = vi.fn(async () => ({ ok: false, error: 'mount_not_declared' }) as UndeclareResult);
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ undeclareMount, listMounts }) as never);

    const result = await store.undeclare('primary', 6);

    expect(result).toEqual({ ok: false, error: 'mount_not_declared' });
    expect(listMounts).not.toHaveBeenCalled();
  });
});

describe('MountsStore.doctor', () => {
  it('threads generation to the api and returns the checks payload WITHOUT refreshing the catalog (a read-only probe, A2-T9)', async () => {
    const mountsDoctor = vi.fn(
      async () => ({ ok: true, data: { ok: false, checks: [{ id: 'manifest_ok:primary' }] } }) as DoctorResult
    );
    const listMounts = vi.fn(async () => ({ ok: true, data: { mounts: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ mountsDoctor, listMounts }) as never);

    const result = await store.doctor(7);

    expect(mountsDoctor).toHaveBeenCalledWith(7);
    expect(listMounts).not.toHaveBeenCalled();
    expect(result).toEqual({ ok: true, data: { ok: false, checks: [{ id: 'manifest_ok:primary' }] } });
  });

  it('surfaces the error code on failure', async () => {
    const mountsDoctor = vi.fn(async () => ({ ok: false, error: 'workspace_not_open' }) as DoctorResult);
    const store = new MountsStore(fakeApi({ mountsDoctor }) as never);

    const result = await store.doctor(1);

    expect(result).toEqual({ ok: false, error: 'workspace_not_open' });
  });
});

// `declareMount`'s error vocabulary (`Valea.Api.Mounts.error_for/1`): the
// generation guard's own two codes, `Valea.Mounts.validate_mount_name/1`'s
// `invalid_mount_name`, and all EIGHT of
// `Valea.Mounts.External.validate_ref/2`'s reason atoms (see that
// function's @doc) — table-tested so every one of the 8 gets an actually
// readable message, not a raw code dumped on screen.
describe('declareMountErrorMessage', () => {
  const cases: Array<[string, string]> = [
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['invalid_mount_name', 'Give this mount a name without "/", "..", or control characters.'],
    ['not_absolute', "Enter a full path (or one starting with ~) — a relative path can't be mounted."],
    ['inside_workspace', "That folder is already inside this workspace — it doesn't need mounting."],
    [
      'ancestor_of_workspace',
      'That folder contains this workspace — mounting it would put the workspace inside itself.'
    ],
    ['home_or_root', "That's your entire home folder (or your whole disk) — pick something more specific."],
    ['not_found', "That folder doesn't exist. Check the path and try again."],
    ['no_manifest', "That folder doesn't look like a knowledge module yet — it needs an icm.yaml."],
    [
      'unsafe_path',
      "That path contains a character (*, ?, [, ], {, }, ( or )) that isn't safe to mount. Rename the folder or choose another."
    ],
    ['invalid_manifest', 'That folder has an icm.yaml, but it could not be read. Check its contents and try again.']
  ];

  it.each(cases)('maps %s to its exact readable message', (code, expected) => {
    expect(declareMountErrorMessage(code)).toBe(expected);
  });

  it('falls back to a generic message for an unrecognized code', () => {
    expect(declareMountErrorMessage('mystery_code')).toBe('Could not mount that folder. Check the path and try again.');
  });
});

describe('undeclareMountErrorMessage', () => {
  const cases: Array<[string, string]> = [
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['mount_not_declared', "That mount isn't a by-reference mount — there's nothing to unmount."]
  ];

  it.each(cases)('maps %s to its exact readable message', (code, expected) => {
    expect(undeclareMountErrorMessage(code)).toBe(expected);
  });

  it('falls back to a generic message for an unrecognized code', () => {
    expect(undeclareMountErrorMessage('mystery_code')).toBe('Could not unmount that folder. Try again.');
  });
});

// Fix wave 1 (A2-T9): a declare-stage failure during reference-adoption
// happens AFTER `workspaceStore.create` already flipped `state = 'open'` —
// the onboarding card is unmounted by then, so its local `referenceError`
// write is a no-op. `pendingAdoptError` persists the failure across that
// transition; the Knowledge page renders it as a dismissible banner.
describe('MountsStore.pendingAdoptError', () => {
  it('starts null', () => {
    const store = new MountsStore(fakeApi({}) as never);
    expect(store.pendingAdoptError).toBeNull();
  });

  it('setPendingAdoptError stores name/ref/message; clearPendingAdoptError resets to null (dismiss)', () => {
    const store = new MountsStore(fakeApi({}) as never);

    store.setPendingAdoptError('client-notes', '/Users/mara/Documents/Client Notes', 'mapped message');
    expect(store.pendingAdoptError).toEqual({
      name: 'client-notes',
      ref: '/Users/mara/Documents/Client Notes',
      message: 'mapped message'
    });

    store.clearPendingAdoptError();
    expect(store.pendingAdoptError).toBeNull();
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
