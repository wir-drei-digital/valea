import { describe, expect, it, test, vi } from 'vitest';
import {
  adoptExisting,
  createNewIcm,
  mountExisting,
  type AdoptExistingDeps,
  type CreateNewIcmDeps,
  type IcmInspection,
  type MountExistingDeps
} from './mount-icm-action';

// Task 10.4: the in-app "Mount an existing ICM…" orchestration — fake-deps-
// injection, no real store or RPC round trip. No `createWorkspace` step and
// `generation` is a plain number, unlike `useExistingIcm` (onboarding-path.ts).
describe('mountExisting', () => {
  const healthyInspection: IcmInspection = {
    ok: true,
    name: 'Client Notes',
    description: 'Old client work',
    reason: null,
    adoptable: false
  };
  const unhealthyInspection: IcmInspection = {
    ok: false,
    name: null,
    description: null,
    reason: 'no icm.yaml found in that folder',
    adoptable: false
  };

  function fakeDeps(overrides: Partial<MountExistingDeps> = {}): MountExistingDeps {
    return {
      inspectIcm: overrides.inspectIcm ?? (async () => ({ ok: true, data: healthyInspection })),
      mountIcm: overrides.mountIcm ?? (async () => ({ ok: true, mountKey: 'client-notes' }))
    };
  }

  it('inspects, then mounts by reference using the CALLER-SUPPLIED generation', async () => {
    const inspectIcm = vi.fn(async () => ({ ok: true, data: healthyInspection }) as const);
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'client-notes' }) as const);

    const result = await mountExisting(
      '/Users/mara/Documents/Client Notes',
      7,
      fakeDeps({ inspectIcm, mountIcm })
    );

    expect(inspectIcm).toHaveBeenCalledWith('/Users/mara/Documents/Client Notes');
    expect(mountIcm).toHaveBeenCalledWith('/Users/mara/Documents/Client Notes', 7);
    expect(result).toEqual({ ok: true, mountKey: 'client-notes' });
  });

  it('stops before mounting when the path is not a healthy ICM — surfaces the reason verbatim', async () => {
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);

    const result = await mountExisting(
      '/Users/mara/Downloads',
      1,
      fakeDeps({ inspectIcm: async () => ({ ok: true, data: unhealthyInspection }), mountIcm })
    );

    expect(result).toEqual({ ok: false, stage: 'inspect', error: 'no icm.yaml found in that folder' });
    expect(mountIcm).not.toHaveBeenCalled();
  });

  it('stops before mounting on an RPC-level inspect failure', async () => {
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);

    const result = await mountExisting(
      '/Users/mara/Documents/Client Notes',
      1,
      fakeDeps({ inspectIcm: async () => ({ ok: false, error: 'unknown_error' }), mountIcm })
    );

    expect(result).toEqual({ ok: false, stage: 'inspect', error: 'unknown_error' });
    expect(mountIcm).not.toHaveBeenCalled();
  });

  it('surfaces a mount-stage failure with the raw code — the caller maps it to copy, no persisted banner/navigation here', async () => {
    const result = await mountExisting(
      '/Users/mara/Documents/Client Notes',
      1,
      fakeDeps({ mountIcm: async () => ({ ok: false, error: 'no_manifest' }) })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'no_manifest' });
  });

  test('mountExisting surfaces an adoptable folder instead of a dead-end error', async () => {
    const deps = {
      inspectIcm: async () => ({
        ok: true as const,
        data: { ok: false, name: null, description: null, reason: 'no icm.yaml found in that folder', adoptable: true }
      }),
      mountIcm: async () => {
        throw new Error('must not mount');
      }
    };
    const outcome = await mountExisting('/tmp/life', 1, deps);
    expect(outcome).toEqual({
      ok: false,
      stage: 'adoptable',
      inspection: expect.objectContaining({ adoptable: true })
    });
  });

  test('a non-adoptable inspect failure keeps the old inspect-stage shape', async () => {
    const deps = {
      inspectIcm: async () => ({
        ok: true as const,
        data: { ok: false, name: null, description: null, reason: 'manifest is garbage', adoptable: false }
      }),
      mountIcm: async () => ({ ok: true as const, mountKey: 'x' })
    };
    const outcome = await mountExisting('/tmp/x', 1, deps);
    expect(outcome).toEqual({ ok: false, stage: 'inspect', error: 'manifest is garbage' });
  });
});

// Task 13: minting the identity file (icm.yaml) into a folder that isn't a
// Valea ICM yet, then mounting it by reference — the one consented write the
// adoptable-folder flag exists to gate. Same shape as `mountExisting`'s
// mount step, ONE call.
describe('adoptExisting', () => {
  function fakeDeps(overrides: Partial<AdoptExistingDeps> = {}): AdoptExistingDeps {
    return {
      adoptIcm: overrides.adoptIcm ?? (async () => ({ ok: true, mountKey: 'life' }))
    };
  }

  test('adoptExisting mints then reports the mount key', async () => {
    const calls: unknown[] = [];
    const deps = {
      adoptIcm: async (path: string, name: string, generation: number) => {
        calls.push([path, name, generation]);
        return { ok: true as const, mountKey: 'life' };
      }
    };
    const outcome = await adoptExisting('/tmp/life', 'Life', 1, deps);
    expect(outcome).toEqual({ ok: true, mountKey: 'life' });
    expect(calls).toEqual([['/tmp/life', 'Life', 1]]);
  });

  it('surfaces an adopt failure at the "mount" stage with the raw code', async () => {
    const result = await adoptExisting(
      '/tmp/life',
      'Life',
      1,
      fakeDeps({ adoptIcm: async () => ({ ok: false, error: 'already_exists' }) })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'already_exists' });
  });
});

// Task 10.4: the in-app "Create a new ICM…" orchestration.
describe('createNewIcm', () => {
  function fakeDeps(overrides: Partial<CreateNewIcmDeps> = {}): CreateNewIcmDeps {
    return {
      createIcm: overrides.createIcm ?? (async () => ({ ok: true, mountKey: 'coaching-practice' }))
    };
  }

  it('creates the ICM at folder using the caller-supplied generation, and returns its mountKey', async () => {
    const createIcm = vi.fn(async () => ({ ok: true, mountKey: 'coaching-practice' }) as const);

    const result = await createNewIcm(
      'Coaching Practice',
      '~/Documents/Valea/Coaching Practice',
      4,
      fakeDeps({ createIcm })
    );

    expect(createIcm).toHaveBeenCalledWith('Coaching Practice', '~/Documents/Valea/Coaching Practice', 4);
    expect(result).toEqual({ ok: true, mountKey: 'coaching-practice' });
  });

  it('surfaces a create failure with the raw code — the caller maps it to copy', async () => {
    const result = await createNewIcm(
      'Name',
      '~/Documents/Valea/Name',
      1,
      fakeDeps({ createIcm: async () => ({ ok: false, error: 'already_exists' }) })
    );

    expect(result).toEqual({ ok: false, error: 'already_exists' });
  });
});
