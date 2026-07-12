import { describe, expect, it } from 'vitest';
import { basename, decideOnboardingMode, dirname, slugify } from './onboarding-path';
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
