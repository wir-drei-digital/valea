import { describe, expect, it, test, vi } from 'vitest';
import {
  adoptExistingIcm,
  basename,
  defaultIcmFolder,
  startFresh,
  useExistingIcm,
  type AdoptExistingIcmDeps,
  type IcmInspection,
  type StartFreshDeps,
  type UseExistingIcmDeps
} from './onboarding-path';

describe('basename', () => {
  it('returns the last path segment', () => {
    expect(basename('/Users/mara/Documents/Client Notes')).toBe('Client Notes');
  });

  it('strips a trailing slash before taking the last segment', () => {
    expect(basename('/Users/mara/Documents/Client Notes/')).toBe('Client Notes');
  });

  it('returns the whole string when there is no slash', () => {
    expect(basename('just-a-name')).toBe('just-a-name');
  });
});

// Task 10.2: "Start fresh" — live folder suggestion shown in
// `CreateWorkspaceDialog.svelte` as the ICM name field is typed.
describe('defaultIcmFolder', () => {
  it('suggests ~/Documents/Valea/<name> for a non-blank name', () => {
    expect(defaultIcmFolder('Coaching Practice')).toBe('~/Documents/Valea/Coaching Practice');
  });

  it('trims surrounding whitespace before building the suggestion', () => {
    expect(defaultIcmFolder('  Client Notes  ')).toBe('~/Documents/Valea/Client Notes');
  });

  it('falls back to the bare Valea folder for a blank/whitespace-only name', () => {
    expect(defaultIcmFolder('')).toBe('~/Documents/Valea');
    expect(defaultIcmFolder('   ')).toBe('~/Documents/Valea');
  });
});

// Task 10.2: the "Start fresh" orchestration — fake-deps-injection, no real
// store or RPC round trip.
describe('startFresh', () => {
  function fakeDeps(overrides: Partial<StartFreshDeps> = {}): StartFreshDeps {
    return {
      createWorkspace: overrides.createWorkspace ?? (async () => ({ ok: true })),
      createIcm: overrides.createIcm ?? (async () => ({ ok: true, mountKey: 'coaching-practice' })),
      currentGeneration: overrides.currentGeneration ?? (() => 1),
      setPendingIcmError: overrides.setPendingIcmError ?? (() => {}),
      goToKnowledge: overrides.goToKnowledge ?? (() => {}),
      goToFirstSession: overrides.goToFirstSession ?? (() => {})
    };
  }

  it('creates the workspace, then creates the ICM at folder using the POST-CREATE generation, then navigates to its first session', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const createIcm = vi.fn(async () => ({ ok: true, mountKey: 'coaching-practice' }) as const);
    const currentGeneration = vi.fn(() => 3);
    const goToFirstSession = vi.fn();

    const result = await startFresh(
      'Coaching Practice',
      '~/Documents/Valea/Coaching Practice',
      null,
      fakeDeps({ createWorkspace, createIcm, currentGeneration, goToFirstSession })
    );

    // no explicit workspaceName -> the workspace name defaults to the ICM name.
    expect(createWorkspace).toHaveBeenCalledWith('Coaching Practice');
    expect(createIcm).toHaveBeenCalledWith('Coaching Practice', '~/Documents/Valea/Coaching Practice', 3);
    // generation is read AFTER createWorkspace resolves, never before.
    expect(currentGeneration).toHaveBeenCalledTimes(1);
    expect(goToFirstSession).toHaveBeenCalledWith('coaching-practice');
    expect(result).toEqual({ ok: true, mountKey: 'coaching-practice' });
  });

  // Brief: "Workspace name defaults from the ICM name, adjustable in a
  // secondary field" — the adjusted case: the two names diverge, the
  // workspace gets the override, the ICM keeps its own name.
  it('uses the explicit workspaceName for createWorkspace while createIcm keeps the ICM name', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const createIcm = vi.fn(async () => ({ ok: true, mountKey: 'coaching-practice' }) as const);

    await startFresh(
      'Coaching Practice',
      '~/Documents/Valea/Coaching Practice',
      'Mara Coaching Co',
      fakeDeps({ createWorkspace, createIcm })
    );

    expect(createWorkspace).toHaveBeenCalledWith('Mara Coaching Co');
    expect(createIcm).toHaveBeenCalledWith('Coaching Practice', '~/Documents/Valea/Coaching Practice', 1);
  });

  it('falls back to the ICM name when workspaceName is blank/whitespace', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);

    await startFresh('Coaching Practice', '~/Documents/Valea/Coaching Practice', '   ', fakeDeps({ createWorkspace }));

    expect(createWorkspace).toHaveBeenCalledWith('Coaching Practice');
  });

  it('short-circuits on a create-workspace failure — never calls createIcm, never persists an error, never navigates', async () => {
    const createIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingIcmError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToFirstSession = vi.fn();

    const result = await startFresh(
      'Name',
      '~/Documents/Valea/Name',
      null,
      fakeDeps({
        createWorkspace: async () => ({ ok: false, error: 'some_error' }),
        createIcm,
        setPendingIcmError,
        goToKnowledge,
        goToFirstSession
      })
    );

    expect(result).toEqual({ ok: false, stage: 'create-workspace', error: 'some_error' });
    expect(createIcm).not.toHaveBeenCalled();
    expect(setPendingIcmError).not.toHaveBeenCalled();
    expect(goToKnowledge).not.toHaveBeenCalled();
    expect(goToFirstSession).not.toHaveBeenCalled();
  });

  // Fix wave: the persisted message maps through `createIcmErrorMessage`,
  // not `declareMountErrorMessage` — nothing was mounted here, so "could not
  // mount that folder" would misdescribe an `already_exists` (the target
  // folder already holds an icm.yaml).
  it('surfaces a create-ICM failure at the "create-icm" stage, persists it with the CREATE-specific mapped message, and navigates to Knowledge', async () => {
    const setPendingIcmError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToFirstSession = vi.fn();

    const result = await startFresh(
      'Name',
      '~/Documents/Valea/Name',
      null,
      fakeDeps({
        createIcm: async () => ({ ok: false, error: 'already_exists' }),
        setPendingIcmError,
        goToKnowledge,
        goToFirstSession
      })
    );

    expect(result).toEqual({ ok: false, stage: 'create-icm', error: 'already_exists' });
    expect(setPendingIcmError).toHaveBeenCalledWith(
      'Name',
      '~/Documents/Valea/Name',
      'That folder already holds an ICM — choose "Use an existing ICM folder" to mount it instead.'
    );
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
    expect(goToFirstSession).not.toHaveBeenCalled();
  });

  it('maps an unrecognized create-ICM failure to the create-specific generic copy, not the mount copy', async () => {
    const setPendingIcmError = vi.fn();

    await startFresh(
      'Name',
      '~/Documents/Valea/Name',
      null,
      fakeDeps({ createIcm: async () => ({ ok: false, error: 'mystery_code' }), setPendingIcmError })
    );

    expect(setPendingIcmError).toHaveBeenCalledWith(
      'Name',
      '~/Documents/Valea/Name',
      'Could not create the ICM folder. Check the location and try again.'
    );
  });

  it('surfaces workspace_not_open at the create-icm stage when the post-create generation is unavailable, without calling createIcm — persists AND navigates too (the transition already happened)', async () => {
    const createIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingIcmError = vi.fn();
    const goToKnowledge = vi.fn();

    const result = await startFresh(
      'Name',
      '~/Documents/Valea/Name',
      null,
      fakeDeps({ currentGeneration: () => null, createIcm, setPendingIcmError, goToKnowledge })
    );

    expect(result).toEqual({ ok: false, stage: 'create-icm', error: 'workspace_not_open' });
    expect(createIcm).not.toHaveBeenCalled();
    expect(setPendingIcmError).toHaveBeenCalledWith('Name', '~/Documents/Valea/Name', 'No workspace is open.');
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
  });
});

// Task 10.3: the "Use existing ICM" orchestration — fake-deps-injection, no
// real store or RPC round trip.
describe('useExistingIcm', () => {
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

  function fakeDeps(overrides: Partial<UseExistingIcmDeps> = {}): UseExistingIcmDeps {
    return {
      inspectIcm: overrides.inspectIcm ?? (async () => ({ ok: true, data: healthyInspection })),
      createWorkspace: overrides.createWorkspace ?? (async () => ({ ok: true })),
      mountIcm: overrides.mountIcm ?? (async () => ({ ok: true, mountKey: 'client-notes' })),
      currentGeneration: overrides.currentGeneration ?? (() => 1),
      setPendingMountError: overrides.setPendingMountError ?? (() => {}),
      goToKnowledge: overrides.goToKnowledge ?? (() => {}),
      goToMountedIcm: overrides.goToMountedIcm ?? (() => {})
    };
  }

  it('inspects, then creates the workspace (named from the ICM manifest), then mounts by reference using the POST-CREATE generation, then navigates to the mounted ICM', async () => {
    const inspectIcm = vi.fn(async () => ({ ok: true, data: healthyInspection }) as const);
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'client-notes' }) as const);
    const currentGeneration = vi.fn(() => 5);
    const goToMountedIcm = vi.fn();

    const result = await useExistingIcm(
      '/Users/mara/Documents/Client Notes',
      null,
      fakeDeps({ inspectIcm, createWorkspace, mountIcm, currentGeneration, goToMountedIcm })
    );

    expect(inspectIcm).toHaveBeenCalledWith('/Users/mara/Documents/Client Notes');
    // no explicit workspaceName -> falls back to the manifest's own name.
    expect(createWorkspace).toHaveBeenCalledWith('Client Notes');
    expect(mountIcm).toHaveBeenCalledWith('/Users/mara/Documents/Client Notes', 5);
    expect(currentGeneration).toHaveBeenCalledTimes(1);
    expect(goToMountedIcm).toHaveBeenCalledWith('client-notes');
    expect(result).toEqual({ ok: true, mountKey: 'client-notes' });
  });

  it('uses the explicit workspaceName when given, instead of the ICM name', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);

    await useExistingIcm('/Users/mara/Documents/Client Notes', 'Mara Coaching Co', fakeDeps({ createWorkspace }));

    expect(createWorkspace).toHaveBeenCalledWith('Mara Coaching Co');
  });

  it('falls back to the ICM name when workspaceName is blank/whitespace', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);

    await useExistingIcm('/Users/mara/Documents/Client Notes', '   ', fakeDeps({ createWorkspace }));

    expect(createWorkspace).toHaveBeenCalledWith('Client Notes');
  });

  it('falls back to the folder basename when the manifest has no (or a blank) name', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const inspectIcm = async () =>
      ({ ok: true, data: { ok: true, name: '  ', description: null, reason: null, adoptable: false } }) as const;

    await useExistingIcm('/Users/mara/Documents/my-notes', null, fakeDeps({ inspectIcm, createWorkspace }));

    expect(createWorkspace).toHaveBeenCalledWith('my-notes');
  });

  it('stops before creating a workspace when the path is not a healthy ICM — surfaces the reason verbatim', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);

    const result = await useExistingIcm(
      '/Users/mara/Downloads',
      null,
      fakeDeps({ inspectIcm: async () => ({ ok: true, data: unhealthyInspection }), createWorkspace, mountIcm })
    );

    expect(result).toEqual({ ok: false, stage: 'inspect', error: 'no icm.yaml found in that folder' });
    expect(createWorkspace).not.toHaveBeenCalled();
    expect(mountIcm).not.toHaveBeenCalled();
  });

  it('stops before creating a workspace on an RPC-level inspect failure', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);

    const result = await useExistingIcm(
      '/Users/mara/Documents/Client Notes',
      null,
      fakeDeps({ inspectIcm: async () => ({ ok: false, error: 'unknown_error' }), createWorkspace })
    );

    expect(result).toEqual({ ok: false, stage: 'inspect', error: 'unknown_error' });
    expect(createWorkspace).not.toHaveBeenCalled();
  });

  it('short-circuits on a create-workspace failure — never calls mountIcm, never persists an error, never navigates', async () => {
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToMountedIcm = vi.fn();

    const result = await useExistingIcm(
      '/Users/mara/Documents/Client Notes',
      null,
      fakeDeps({
        createWorkspace: async () => ({ ok: false, error: 'some_error' }),
        mountIcm,
        setPendingMountError,
        goToKnowledge,
        goToMountedIcm
      })
    );

    expect(result).toEqual({ ok: false, stage: 'create-workspace', error: 'some_error' });
    expect(mountIcm).not.toHaveBeenCalled();
    expect(setPendingMountError).not.toHaveBeenCalled();
    expect(goToKnowledge).not.toHaveBeenCalled();
    expect(goToMountedIcm).not.toHaveBeenCalled();
  });

  it('surfaces a mount failure at the "mount" stage, persists it with the MAPPED message, and navigates to (bare) Knowledge', async () => {
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToMountedIcm = vi.fn();

    const result = await useExistingIcm(
      '/Users/mara/Documents/Client Notes',
      null,
      fakeDeps({
        mountIcm: async () => ({ ok: false, error: 'no_manifest' }),
        setPendingMountError,
        goToKnowledge,
        goToMountedIcm
      })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'no_manifest' });
    expect(setPendingMountError).toHaveBeenCalledWith(
      'Client Notes',
      '/Users/mara/Documents/Client Notes',
      "That folder doesn't look like a knowledge module yet — it needs an icm.yaml."
    );
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
    expect(goToMountedIcm).not.toHaveBeenCalled();
  });

  it('surfaces workspace_not_open at the mount stage when the post-create generation is unavailable, without calling mountIcm — persists AND navigates too (the transition already happened)', async () => {
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();

    const result = await useExistingIcm(
      '/Users/mara/Documents/Client Notes',
      null,
      fakeDeps({ currentGeneration: () => null, mountIcm, setPendingMountError, goToKnowledge })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'workspace_not_open' });
    expect(mountIcm).not.toHaveBeenCalled();
    expect(setPendingMountError).toHaveBeenCalledWith(
      'Client Notes',
      '/Users/mara/Documents/Client Notes',
      'No workspace is open.'
    );
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
  });

  test('useExistingIcm surfaces an adoptable folder instead of a dead-end error, BEFORE creating a workspace', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const mountIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);

    const outcome = await useExistingIcm(
      '/tmp/life',
      null,
      fakeDeps({
        inspectIcm: async () => ({
          ok: true,
          data: { ok: false, name: null, description: null, reason: 'no icm.yaml found in that folder', adoptable: true }
        }),
        createWorkspace,
        mountIcm
      })
    );

    expect(outcome).toEqual({
      ok: false,
      stage: 'adoptable',
      inspection: expect.objectContaining({ adoptable: true })
    });
    expect(createWorkspace).not.toHaveBeenCalled();
    expect(mountIcm).not.toHaveBeenCalled();
  });
});

// Task 13: the onboarding twin of `mount-icm-action.ts`'s `adoptExisting` —
// runs AFTER the consent step's own `inspect_icm` call already flagged the
// folder `adoptable`, so it takes no `inspectIcm` dependency of its own.
// Same create-workspace/post-create-generation/mount-stage shape
// `useExistingIcm` gives its own mount step above, with `adoptIcm` in place
// of `mountIcm` and the user-typed `name` (no manifest exists yet) standing
// in for the manifest name everywhere `useExistingIcm` would have read one.
describe('adoptExistingIcm', () => {
  function fakeDeps(overrides: Partial<AdoptExistingIcmDeps> = {}): AdoptExistingIcmDeps {
    return {
      createWorkspace: overrides.createWorkspace ?? (async () => ({ ok: true })),
      adoptIcm: overrides.adoptIcm ?? (async () => ({ ok: true, mountKey: 'life' })),
      currentGeneration: overrides.currentGeneration ?? (() => 1),
      setPendingMountError: overrides.setPendingMountError ?? (() => {}),
      goToKnowledge: overrides.goToKnowledge ?? (() => {}),
      goToMountedIcm: overrides.goToMountedIcm ?? (() => {})
    };
  }

  test('creates the workspace, then adopts using the POST-CREATE generation, then navigates to the mounted ICM', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const adoptIcm = vi.fn(async () => ({ ok: true, mountKey: 'life' }) as const);
    const currentGeneration = vi.fn(() => 5);
    const goToMountedIcm = vi.fn();

    const result = await adoptExistingIcm(
      '/tmp/life',
      null,
      'Life',
      fakeDeps({ createWorkspace, adoptIcm, currentGeneration, goToMountedIcm })
    );

    // no explicit workspaceName -> the workspace name defaults to the user-typed ICM name.
    expect(createWorkspace).toHaveBeenCalledWith('Life');
    expect(adoptIcm).toHaveBeenCalledWith('/tmp/life', 'Life', 5);
    expect(currentGeneration).toHaveBeenCalledTimes(1);
    expect(goToMountedIcm).toHaveBeenCalledWith('life');
    expect(result).toEqual({ ok: true, mountKey: 'life' });
  });

  test('uses the explicit workspaceName when given, instead of the user-typed ICM name', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);

    await adoptExistingIcm('/tmp/life', 'Mara Coaching Co', 'Life', fakeDeps({ createWorkspace }));

    expect(createWorkspace).toHaveBeenCalledWith('Mara Coaching Co');
  });

  it('short-circuits on a create-workspace failure — never calls adoptIcm, never persists an error, never navigates', async () => {
    const adoptIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToMountedIcm = vi.fn();

    const result = await adoptExistingIcm(
      '/tmp/life',
      null,
      'Life',
      fakeDeps({
        createWorkspace: async () => ({ ok: false, error: 'some_error' }),
        adoptIcm,
        setPendingMountError,
        goToKnowledge,
        goToMountedIcm
      })
    );

    expect(result).toEqual({ ok: false, stage: 'create-workspace', error: 'some_error' });
    expect(adoptIcm).not.toHaveBeenCalled();
    expect(setPendingMountError).not.toHaveBeenCalled();
    expect(goToKnowledge).not.toHaveBeenCalled();
    expect(goToMountedIcm).not.toHaveBeenCalled();
  });

  test('surfaces an adopt failure at the "mount" stage, persists it with the MAPPED message, and navigates to (bare) Knowledge', async () => {
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();
    const goToMountedIcm = vi.fn();

    const result = await adoptExistingIcm(
      '/tmp/life',
      null,
      'Life',
      fakeDeps({
        adoptIcm: async () => ({ ok: false, error: 'already_exists' }),
        setPendingMountError,
        goToKnowledge,
        goToMountedIcm
      })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'already_exists' });
    expect(setPendingMountError).toHaveBeenCalledWith(
      'Life',
      '/tmp/life',
      'Could not mount that folder. Check the path and try again.'
    );
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
    expect(goToMountedIcm).not.toHaveBeenCalled();
  });

  it('surfaces workspace_not_open at the mount stage when the post-create generation is unavailable, without calling adoptIcm — persists AND navigates too (the transition already happened)', async () => {
    const adoptIcm = vi.fn(async () => ({ ok: true, mountKey: 'x' }) as const);
    const setPendingMountError = vi.fn();
    const goToKnowledge = vi.fn();

    const result = await adoptExistingIcm(
      '/tmp/life',
      null,
      'Life',
      fakeDeps({ currentGeneration: () => null, adoptIcm, setPendingMountError, goToKnowledge })
    );

    expect(result).toEqual({ ok: false, stage: 'mount', error: 'workspace_not_open' });
    expect(adoptIcm).not.toHaveBeenCalled();
    expect(setPendingMountError).toHaveBeenCalledWith('Life', '/tmp/life', 'No workspace is open.');
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
  });
});
