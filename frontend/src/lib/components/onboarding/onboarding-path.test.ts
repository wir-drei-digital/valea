import { describe, expect, it, vi } from 'vitest';
import {
  adoptByReference,
  basename,
  decideOnboardingMode,
  defaultAdoptAction,
  dirname,
  slugify,
  type ReferenceAdoptDeps
} from './onboarding-path';
import type { PathInspection } from '$lib/api/client';

const workspaceInspection: PathInspection = { kind: 'workspace', name: null, description: null };
const otherInspection: PathInspection = { kind: 'other', name: null, description: null };
const icmInspection: PathInspection = {
  kind: 'icm',
  name: 'Client Notes',
  description: 'Old client work'
};

describe('decideOnboardingMode', () => {
  it('picks "open" for kind: workspace', () => {
    expect(decideOnboardingMode(workspaceInspection, '/Users/mara/Business')).toEqual({ mode: 'open' });
  });

  it('picks "unsupported" for kind: other', () => {
    expect(decideOnboardingMode(otherInspection, '/Users/mara/Downloads')).toEqual({ mode: 'unsupported' });
  });

  it('picks "adopt" for kind: icm, carrying the ORIGINAL path and the manifest description', () => {
    const mode = decideOnboardingMode(
      { kind: 'icm', name: 'Coaching Brain', description: 'Old client work' },
      '/Users/mara/Documents/Client Notes'
    );
    expect(mode).toEqual({
      mode: 'adopt',
      originalPath: '/Users/mara/Documents/Client Notes',
      suggestedName: 'Coaching Brain',
      description: 'Old client work'
    });
  });

  // Default adopt config must never collide with the source itself: the
  // consent step prefills parentDir = dirname(source), so a suggestedName
  // equal to the source's own basename would make target == source and the
  // backend would bounce it. The name gets " Workspace" appended instead.
  it('adjusts suggestedName when the manifest name equals the folder basename (default target would BE the source)', () => {
    const mode = decideOnboardingMode(icmInspection, '/Users/mara/Documents/Client Notes');
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('Client Notes Workspace');
      // the adjusted default target is no longer the source path
      expect(`${dirname(mode.originalPath)}/${mode.suggestedName}`).not.toBe(mode.originalPath);
    }
  });

  it('leaves suggestedName unchanged when the manifest name differs from the folder basename', () => {
    const mode = decideOnboardingMode(
      { kind: 'icm', name: 'Coaching Brain', description: null },
      '/Users/mara/Documents/Client Notes'
    );
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('Coaching Brain');
    }
  });

  it('falls back to the folder basename (collision-adjusted) when the manifest has no name', () => {
    const inspection: PathInspection = { kind: 'icm', name: null, description: null };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes');
    expect(mode).toEqual({
      mode: 'adopt',
      originalPath: '/Users/mara/Documents/my-notes',
      // the bare basename would collide with the source (parentDir defaults
      // to the source's own parent), so the fallback is adjusted too
      suggestedName: 'my-notes Workspace',
      description: null
    });
  });

  it('falls back to the folder basename (collision-adjusted) when the manifest name is blank/whitespace', () => {
    const inspection: PathInspection = { kind: 'icm', name: '   ', description: '' };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes');
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('my-notes Workspace');
    }
  });

  it('handles a trailing slash on the original path when computing the basename fallback', () => {
    const inspection: PathInspection = { kind: 'icm', name: null, description: null };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes/');
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('my-notes Workspace');
    }
  });
});

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

describe('dirname', () => {
  it('returns the parent directory', () => {
    expect(dirname('/Users/mara/Documents/Client Notes')).toBe('/Users/mara/Documents');
  });

  it('returns "/" for a top-level path', () => {
    expect(dirname('/Client Notes')).toBe('/');
  });

  it('returns "/" for the root path itself', () => {
    expect(dirname('/')).toBe('/');
  });
});

// Mirrors `Valea.Workspace.Scaffold.slugify/1` (lowercase, ascii-fold,
// non-alphanumeric runs -> "-", "mount" fallback) so the consent card can
// show the exact `mounts/<slug>` destination the backend will move into.
describe('slugify', () => {
  it('lowercases, ascii-folds, and dashes non-alphanumeric runs', () => {
    expect(slugify('Café Löwen & Co.!!')).toBe('cafe-lowen-co');
  });

  it('falls back to "mount" when nothing alphanumeric remains', () => {
    expect(slugify('!!!')).toBe('mount');
  });

  it('passes a plain lowercase name through unchanged', () => {
    expect(slugify('client-notes')).toBe('client-notes');
  });
});

// A2-T9: adopt-by-reference ("Use it where it is") is now the DEFAULT
// action for an ICM-shaped folder — move ("Move it into the workspace")
// stays available but secondary. `defaultAdoptAction` is the single,
// directly-testable source of truth the UI reads for which button gets
// the primary/emphasized treatment, rather than that decision being
// implicit in template button order alone.
describe('defaultAdoptAction', () => {
  it('is "reference" for an "adopt" mode (kind: icm)', () => {
    const mode = decideOnboardingMode(icmInspection, '/Users/mara/Documents/Client Notes');
    expect(defaultAdoptAction(mode)).toBe('reference');
  });

  it('is null for "open" — nothing to default, this is the plain open-workspace path', () => {
    expect(defaultAdoptAction({ mode: 'open' })).toBeNull();
  });

  it('is null for "unsupported"', () => {
    expect(defaultAdoptAction({ mode: 'unsupported' })).toBeNull();
  });
});

// A2-T9: the frontend-side orchestration behind "Use it where it is" —
// there is no backend adopt-by-reference endpoint (`Valea.Workspace.Adopt`
// is move-only), so this sequencing IS the by-reference adoption path:
// scaffold a brand-new workspace the normal way, then declare the external
// folder into it as a by-reference mount. Deps are injected (same shape as
// `mail-shapes.ts`'s `submitMailSetup`) so this is testable without a real
// store or RPC.
describe('adoptByReference', () => {
  function fakeDeps(overrides: Partial<ReferenceAdoptDeps> = {}): ReferenceAdoptDeps {
    return {
      createWorkspace: overrides.createWorkspace ?? (async () => ({ ok: true })),
      declareMount: overrides.declareMount ?? (async () => ({ ok: true })),
      currentGeneration: overrides.currentGeneration ?? (() => 4),
      setPendingAdoptError: overrides.setPendingAdoptError ?? (() => {}),
      goToKnowledge: overrides.goToKnowledge ?? (() => {})
    };
  }

  it('creates the workspace, then declares the source path as an external mount using the POST-CREATE generation', async () => {
    const createWorkspace = vi.fn(async () => ({ ok: true }) as const);
    const declareMount = vi.fn(async () => ({ ok: true }) as const);
    const currentGeneration = vi.fn(() => 4);
    const setPendingAdoptError = vi.fn();
    const goToKnowledge = vi.fn();

    const result = await adoptByReference(
      '/Users/mara/Documents',
      'Coaching Brain Workspace',
      'Client Notes',
      '/Users/mara/Documents/Client Notes',
      { createWorkspace, declareMount, currentGeneration, setPendingAdoptError, goToKnowledge }
    );

    expect(createWorkspace).toHaveBeenCalledWith('/Users/mara/Documents', 'Coaching Brain Workspace');
    expect(declareMount).toHaveBeenCalledWith('Client Notes', '/Users/mara/Documents/Client Notes', 4);
    // generation is read AFTER createWorkspace resolves, never before.
    expect(currentGeneration).toHaveBeenCalledTimes(1);
    expect(result).toEqual({ ok: true });
    // success writes no pending error — nothing to surface later.
    expect(setPendingAdoptError).not.toHaveBeenCalled();
    // success keeps landing on Today (the state flip's natural destination)
    // — no forced navigation (fix wave 2).
    expect(goToKnowledge).not.toHaveBeenCalled();
  });

  // Fix wave 1: a CREATE failure happens while the onboarding card is still
  // mounted (workspaceStore.state never flipped), so the card's own
  // referenceError rendering is the right surface — pendingAdoptError must
  // stay untouched, or a stale banner would greet the user after a LATER
  // successful onboarding.
  it('short-circuits on a create failure — never calls declareMount, never writes pendingAdoptError, never navigates', async () => {
    const declareMount = vi.fn(async () => ({ ok: true }) as const);
    const setPendingAdoptError = vi.fn();
    const goToKnowledge = vi.fn();
    const result = await adoptByReference(
      '/parent',
      'name',
      'mount',
      '/src',
      fakeDeps({
        createWorkspace: async () => ({ ok: false, error: 'target_not_empty' }),
        declareMount,
        setPendingAdoptError,
        goToKnowledge
      })
    );

    expect(result).toEqual({ ok: false, stage: 'create', error: 'target_not_empty' });
    expect(declareMount).not.toHaveBeenCalled();
    expect(setPendingAdoptError).not.toHaveBeenCalled();
    // still on the onboarding screen (state never flipped) — navigating
    // would tear the error out from under the user (fix wave 2).
    expect(goToKnowledge).not.toHaveBeenCalled();
  });

  // Fix wave 1: a DECLARE failure happens AFTER workspaceStore.create flipped
  // state to 'open' — the onboarding card is unmounted by the time this
  // resolves, so its local error state is a dead write. The failure must be
  // persisted (mapped to readable copy here, the one place holding all three
  // of name/ref/code) so the post-transition UI (Knowledge's banner) can
  // surface it.
  it('surfaces a declare failure at the "declare" stage, persists it via setPendingAdoptError with the MAPPED message, AND navigates to Knowledge (where the banner + retry live)', async () => {
    const setPendingAdoptError = vi.fn();
    const goToKnowledge = vi.fn();
    const result = await adoptByReference(
      '/parent',
      'name',
      'Client Notes',
      '/Users/mara/Documents/Client Notes',
      fakeDeps({ declareMount: async () => ({ ok: false, error: 'no_manifest' }), setPendingAdoptError, goToKnowledge })
    );

    expect(result).toEqual({ ok: false, stage: 'declare', error: 'no_manifest' });
    expect(setPendingAdoptError).toHaveBeenCalledWith(
      'Client Notes',
      '/Users/mara/Documents/Client Notes',
      "That folder doesn't look like a knowledge module yet — it needs an icm.yaml."
    );
    // Fix wave 2: post-onboarding the user otherwise lands on Today, where
    // the banner never renders — the declare-failure path must take them to
    // the surface that shows it.
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
  });

  it('surfaces workspace_not_open at the declare stage when the post-create generation is unavailable, without calling declareMount — persists AND navigates too (the transition already happened)', async () => {
    const declareMount = vi.fn(async () => ({ ok: true }) as const);
    const setPendingAdoptError = vi.fn();
    const goToKnowledge = vi.fn();
    const result = await adoptByReference(
      '/parent',
      'name',
      'mount',
      '/src',
      fakeDeps({ currentGeneration: () => null, declareMount, setPendingAdoptError, goToKnowledge })
    );

    expect(result).toEqual({ ok: false, stage: 'declare', error: 'workspace_not_open' });
    expect(declareMount).not.toHaveBeenCalled();
    expect(setPendingAdoptError).toHaveBeenCalledWith('mount', '/src', 'No workspace is open.');
    expect(goToKnowledge).toHaveBeenCalledTimes(1);
  });
});
