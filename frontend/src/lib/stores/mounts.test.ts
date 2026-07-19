import { describe, it, expect, vi } from 'vitest';
import {
  MountsStore,
  mountsStore,
  wireMountsEvents,
  createIcmErrorMessage,
  declareMountErrorMessage,
  undeclareMountErrorMessage
} from './mounts.svelte';
import { icmStore } from './icm.svelte';
import { workspaceStore } from './workspace.svelte';
import type { ApiResult } from '../api/client';
import type { Channel } from 'phoenix';

type ListResult = ApiResult<{ icms: any[] }>;
type SetEnabledResult = ApiResult<{ saved: boolean }>;
type CreateResult = ApiResult<{ mountKey: string; id: string }>;
type UnmountResult = ApiResult<{ unmounted: boolean }>;
type DoctorResult = ApiResult<{ ok: boolean; checks: unknown[] }>;

function fakeApi(overrides: {
  listIcms?: (generation: number) => Promise<ListResult>;
  setIcmEnabled?: (mountKey: string, enabled: boolean, generation: number) => Promise<SetEnabledResult>;
  createIcm?: (name: string, path: string, generation: number) => Promise<CreateResult>;
  unmountIcm?: (mountKey: string, generation: number) => Promise<UnmountResult>;
  icmDoctor?: (mountKey: string, generation: number) => Promise<DoctorResult>;
}) {
  return {
    listIcms: overrides.listIcms ?? (async () => ({ ok: true, data: { icms: [] } }) as ListResult),
    setIcmEnabled:
      overrides.setIcmEnabled ?? (async () => ({ ok: true, data: { saved: true } }) as SetEnabledResult),
    createIcm:
      overrides.createIcm ??
      (async () => ({ ok: true, data: { mountKey: 'x', id: 'id-x' } }) as CreateResult),
    unmountIcm:
      overrides.unmountIcm ?? (async () => ({ ok: true, data: { unmounted: true } }) as UnmountResult),
    icmDoctor:
      overrides.icmDoctor ?? (async () => ({ ok: true, data: { ok: true, checks: [] } }) as DoctorResult)
  };
}

describe('MountsStore.refresh', () => {
  it('populates mounts and flips loaded on success', async () => {
    const rawIcms = [
      {
        mountKey: 'primary',
        id: '11111111-1111-1111-1111-111111111111',
        name: 'Primary',
        description: 'The default mount',
        root: '/ws/primary',
        enabled: true,
        degraded: null
      },
      {
        mountKey: 'clients',
        id: null,
        name: 'Clients',
        description: 'Client-facing docs',
        root: '/ws/clients',
        enabled: false,
        degraded: 'manifest_missing'
      }
    ];
    const store = new MountsStore(fakeApi({ listIcms: async () => ({ ok: true, data: { icms: rawIcms } }) }) as never);

    await store.refresh();

    expect(store.loaded).toBe(true);
    expect(store.mounts).toEqual(rawIcms);
  });

  it('leaves mounts/loaded untouched on failure', async () => {
    const store = new MountsStore(fakeApi({ listIcms: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never);

    await store.refresh();

    expect(store.loaded).toBe(false);
    expect(store.mounts).toEqual([]);
  });

  it('falls back to workspaceStore.generation when called bare (no explicit generation)', async () => {
    workspaceStore.generation = 42;
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ listIcms }) as never);

    await store.refresh();

    expect(listIcms).toHaveBeenCalledWith(42);
    workspaceStore.generation = null;
  });

  // Acceptance fix wave (Task 9.3/9.4 re-review Finding 2 — generation-coherent
  // refresh): `handleWorkspaceEvent` (icm.svelte.ts) needs to override the
  // workspaceStore fallback with the workspace-change push's OWN generation,
  // since workspaceStore.generation is guaranteed stale (still the OUTGOING
  // workspace's value) at that exact call site — see that function's doc
  // comment.
  it('prefers an explicit generation argument over workspaceStore.generation', async () => {
    workspaceStore.generation = 1; // stale — the OUTGOING workspace's generation
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ listIcms }) as never);

    await store.refresh(7); // the INCOMING workspace's generation, from the event payload

    expect(listIcms).toHaveBeenCalledWith(7);
    workspaceStore.generation = null;
  });

  // Reproduces the actual bug: a fake backend that only accepts the CURRENT
  // (incoming) generation, exactly like `Valea.Api.Icms`'s `check_generation/1`
  // guard rejecting a stale one with `workspace_changed`. Calling `refresh()`
  // bare while `workspaceStore.generation` still holds the outgoing value
  // fails and leaves the catalog empty (the bug); threading the event's own
  // generation explicitly succeeds and populates it (the fix).
  it('reproduces the switch-refresh bug: stale workspaceStore.generation is rejected, the event-supplied generation is not', async () => {
    const CURRENT_GENERATION = 7;
    workspaceStore.generation = 1; // stale, from before the switch
    const rawIcms = [
      {
        mountKey: 'consulting-legal',
        id: '22222222-2222-2222-2222-222222222222',
        name: 'Legal',
        description: '',
        root: '/ws/legal',
        enabled: true,
        degraded: null
      }
    ];
    const listIcms = vi.fn(async (generation: number) =>
      generation === CURRENT_GENERATION
        ? ({ ok: true, data: { icms: rawIcms } } as ListResult)
        : ({ ok: false, error: 'workspace_changed' } as ListResult)
    );

    const buggyStore = new MountsStore(fakeApi({ listIcms }) as never);
    await buggyStore.refresh(); // bare — falls back to the stale workspaceStore.generation
    expect(buggyStore.loaded).toBe(false);
    expect(buggyStore.mounts).toEqual([]);

    const fixedStore = new MountsStore(fakeApi({ listIcms }) as never);
    await fixedStore.refresh(CURRENT_GENERATION); // explicit — the event's own generation
    expect(fixedStore.loaded).toBe(true);
    expect(fixedStore.mounts).toEqual(rawIcms);

    workspaceStore.generation = null;
  });
});

describe('MountsStore.setEnabled', () => {
  it('threads mountKey/enabled/generation to the api and refreshes on success', async () => {
    const setIcmEnabled = vi.fn(async () => ({ ok: true, data: { saved: true } }) as SetEnabledResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ setIcmEnabled, listIcms }) as never);

    const result = await store.setEnabled('clients', false, 5);

    expect(setIcmEnabled).toHaveBeenCalledWith('clients', false, 5);
    expect(listIcms).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const setIcmEnabled = vi.fn(async () => ({ ok: false, error: 'workspace_changed' }) as SetEnabledResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ setIcmEnabled, listIcms }) as never);

    const result = await store.setEnabled('clients', true, 1);

    expect(result).toEqual({ ok: false, error: 'workspace_changed' });
    expect(listIcms).not.toHaveBeenCalled();
  });
});

describe('MountsStore.create', () => {
  it('threads name/path/generation and returns mountKey/id on success', async () => {
    const createIcm = vi.fn(async () => ({ ok: true, data: { mountKey: 'new-mount', id: 'id-1' } }) as CreateResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ createIcm, listIcms }) as never);

    const result = await store.create('New Mount', '/Users/dev/new-mount', 9);

    expect(createIcm).toHaveBeenCalledWith('New Mount', '/Users/dev/new-mount', 9);
    expect(listIcms).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true, mountKey: 'new-mount', id: 'id-1' });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const createIcm = vi.fn(async () => ({ ok: false, error: 'already_exists' }) as CreateResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ createIcm, listIcms }) as never);

    const result = await store.create('clients', '', 2);

    expect(result).toEqual({ ok: false, error: 'already_exists' });
    expect(listIcms).not.toHaveBeenCalled();
  });
});

describe('MountsStore.undeclare', () => {
  it('threads mountKey/generation to unmountIcm and refreshes on success', async () => {
    const unmountIcm = vi.fn(async () => ({ ok: true, data: { unmounted: true } }) as UnmountResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ unmountIcm, listIcms }) as never);

    const result = await store.undeclare('client-notes', 6);

    expect(unmountIcm).toHaveBeenCalledWith('client-notes', 6);
    expect(listIcms).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
  });

  it('surfaces the error code and does not refresh on failure', async () => {
    const unmountIcm = vi.fn(async () => ({ ok: false, error: 'mount_not_found' }) as UnmountResult);
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ unmountIcm, listIcms }) as never);

    const result = await store.undeclare('primary', 6);

    expect(result).toEqual({ ok: false, error: 'mount_not_found' });
    expect(listIcms).not.toHaveBeenCalled();
  });
});

describe('MountsStore.doctor', () => {
  it('lists every mount then fans icmDoctor out per mountKey, flattening checks WITHOUT refreshing the catalog', async () => {
    const listIcms = vi.fn(
      async () =>
        ({
          ok: true,
          data: { icms: [{ mountKey: 'primary' }, { mountKey: 'clients' }] }
        }) as ListResult
    );
    const icmDoctor = vi.fn(async (mountKey: string) => ({
      ok: true,
      data: { ok: mountKey === 'primary', checks: [{ id: `manifest_format2:${mountKey}` }] }
    })) as unknown as (mountKey: string, generation: number) => Promise<DoctorResult>;
    const store = new MountsStore(fakeApi({ listIcms, icmDoctor }) as never);

    const result = await store.doctor(7);

    expect(listIcms).toHaveBeenCalledWith(7);
    expect(icmDoctor).toHaveBeenCalledWith('primary', 7);
    expect(icmDoctor).toHaveBeenCalledWith('clients', 7);
    expect(listIcms).toHaveBeenCalledTimes(1);
    expect(result).toEqual({
      ok: true,
      data: {
        ok: false,
        checks: [{ id: 'manifest_format2:primary' }, { id: 'manifest_format2:clients' }]
      }
    });
  });

  it('surfaces the error code when listIcms fails', async () => {
    const listIcms = vi.fn(async () => ({ ok: false, error: 'workspace_not_open' }) as ListResult);
    const store = new MountsStore(fakeApi({ listIcms }) as never);

    const result = await store.doctor(1);

    expect(result).toEqual({ ok: false, error: 'workspace_not_open' });
  });

  it('surfaces the error code when any icmDoctor call fails', async () => {
    const listIcms = vi.fn(
      async () => ({ ok: true, data: { icms: [{ mountKey: 'primary' }] } }) as ListResult
    );
    const icmDoctor = vi.fn(async () => ({ ok: false, error: 'workspace_changed' }) as DoctorResult);
    const store = new MountsStore(fakeApi({ listIcms, icmDoctor }) as never);

    const result = await store.doctor(1);

    expect(result).toEqual({ ok: false, error: 'workspace_changed' });
  });
});

// `declareMount`'s error vocabulary (`Valea.Api.Icms.error_for/1`): the
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
    ['not_absolute', "Enter a full path (or one starting with ~). A relative path can't be used."],
    ['inside_workspace', 'That folder is already inside this workspace, so there is nothing to add.'],
    [
      'ancestor_of_workspace',
      'That folder contains this workspace, so adding it would put the workspace inside itself.'
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

// Task 10.2 fix wave: `create_icm`'s error copy — its own two pre-write
// rejections get create-specific sentences, most boundary/name codes shared
// with `mount_icm` delegate to `declareMountErrorMessage`'s wording, and
// the DEFAULT says "create", not "mount" (nothing was mounted when a
// create fails). Task 11.3: `inside_workspace`/`ancestor_of_workspace` get
// their OWN create-specific wording instead of delegating — the mount
// copy's "doesn't need mounting"/"mounting it would..." phrasing is a
// non-sequitur when nothing was ever mounted.
describe('createIcmErrorMessage', () => {
  const createSpecificCases: Array<[string, string]> = [
    [
      'already_exists',
      'That folder already holds a project. Choose "Use an existing folder" to add it instead.'
    ],
    ['not_a_directory', 'That path points at an existing file, not a folder. Choose a folder location.'],
    [
      'inside_workspace',
      "That folder is inside the app's own storage — choose a folder in your own files."
    ],
    [
      'ancestor_of_workspace',
      "That folder contains the app's own workspace storage — choose a more specific location in your own files."
    ]
  ];

  it.each(createSpecificCases)('maps %s to its create-specific readable message', (code, expected) => {
    expect(createIcmErrorMessage(code)).toBe(expected);
  });

  const sharedCodes = ['workspace_not_open', 'workspace_changed', 'invalid_mount_name', 'not_absolute', 'home_or_root', 'unsafe_path'];

  it.each(sharedCodes)('delegates %s to declareMountErrorMessage (one copy of the shared wording)', (code) => {
    expect(createIcmErrorMessage(code)).toBe(declareMountErrorMessage(code));
  });

  it.each(['inside_workspace', 'ancestor_of_workspace'])(
    '%s does NOT delegate to declareMountErrorMessage (create-specific wording, not mount copy)',
    (code) => {
      expect(createIcmErrorMessage(code)).not.toBe(declareMountErrorMessage(code));
    }
  );

  it('falls back to a CREATE-specific generic message for an unrecognized code — never the mount copy', () => {
    expect(createIcmErrorMessage('mystery_code')).toBe(
      'Could not create the ICM folder. Check the location and try again.'
    );
    expect(createIcmErrorMessage('mystery_code')).not.toBe(declareMountErrorMessage('mystery_code'));
  });
});

describe('undeclareMountErrorMessage', () => {
  const cases: Array<[string, string]> = [
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['mount_not_found', "That mount isn't currently mounted — there's nothing to unmount."]
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
//
// The "successful mount clears the banner" behavior (fix wave 2) is now
// caller-owned — `MountFromElsewhereDialog.svelte`/`OpenWorkspaceFlow.svelte`
// call `clearPendingAdoptError()` themselves after a successful `mount_icm`
// — rather than living inside a store method, so it is not re-tested here.
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

// Browser-verified fix wave: `MountsStore` previously had no `reset()` at
// all, so `wireIcmEvents`'s `onWorkspace` handler (`icm.svelte.ts`) had
// nothing to call on a workspace close/switch — mirrors `IcmStore.reset`'s
// test block in `icm.test.ts` exactly (same three cases).
describe('MountsStore.reset', () => {
  it('empties mounts and clears loaded', async () => {
    const rawIcms = [
      {
        mountKey: 'primary',
        id: '11111111-1111-1111-1111-111111111111',
        name: 'Primary',
        description: 'The default mount',
        root: '/ws/primary',
        enabled: true,
        degraded: null
      }
    ];
    const store = new MountsStore(fakeApi({ listIcms: async () => ({ ok: true, data: { icms: rawIcms } }) }) as never);

    await store.refresh();
    expect(store.loaded).toBe(true);
    expect(store.mounts).toHaveLength(1);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.mounts).toEqual([]);
  });

  it('is safe to call before any refresh has resolved', () => {
    const store = new MountsStore(fakeApi({}) as never);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.mounts).toEqual([]);
  });

  it('allows a subsequent refresh to repopulate the catalog after reset', async () => {
    const rawIcms = [
      {
        mountKey: 'primary',
        id: '11111111-1111-1111-1111-111111111111',
        name: 'Primary',
        description: 'The default mount',
        root: '/ws/primary',
        enabled: true,
        degraded: null
      }
    ];
    const store = new MountsStore(fakeApi({ listIcms: async () => ({ ok: true, data: { icms: rawIcms } }) }) as never);

    await store.refresh();
    store.reset();
    await store.refresh();

    expect(store.loaded).toBe(true);
    expect(store.mounts).toHaveLength(1);
  });

  it('leaves pendingAdoptError untouched — that banner is dismiss-or-overwrite, not workspace-scoped', async () => {
    const store = new MountsStore(fakeApi({}) as never);
    store.setPendingAdoptError('client-notes', '/src', 'mapped message');

    store.reset();

    expect(store.pendingAdoptError).toEqual({ name: 'client-notes', ref: '/src', message: 'mapped message' });
  });
});

describe('MountsStore.handleMountsChanged', () => {
  it('refetches mounts AND triggers the icm store refetch', async () => {
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ListResult);
    const store = new MountsStore(fakeApi({ listIcms }) as never);
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);

    await store.handleMountsChanged();

    expect(listIcms).toHaveBeenCalledTimes(1);
    expect(store.loaded).toBe(true);
    expect(icmRefetch).toHaveBeenCalledTimes(1);

    icmRefetch.mockRestore();
  });
});

// `mountsEventsWired` is a module-level latch (see `mounts.svelte.ts`), so it
// can only be meaningfully exercised ONCE per test file — same convention as
// every other `wire*Events` latch test in this codebase.
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
