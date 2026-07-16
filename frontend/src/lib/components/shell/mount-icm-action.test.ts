import { describe, expect, it, vi } from 'vitest';
import {
  createNewIcm,
  mountExisting,
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
    reason: null
  };
  const unhealthyInspection: IcmInspection = {
    ok: false,
    name: null,
    description: null,
    reason: 'no icm.yaml found in that folder'
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
