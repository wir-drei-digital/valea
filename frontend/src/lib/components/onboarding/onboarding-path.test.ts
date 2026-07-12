import { describe, expect, it } from 'vitest';
import { basename, decideOnboardingMode, dirname } from './onboarding-path';
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

  it('picks "adopt" for kind: icm, carrying the ORIGINAL path and the manifest name/description', () => {
    expect(decideOnboardingMode(icmInspection, '/Users/mara/Documents/Client Notes')).toEqual({
      mode: 'adopt',
      originalPath: '/Users/mara/Documents/Client Notes',
      suggestedName: 'Client Notes',
      description: 'Old client work'
    });
  });

  it('falls back to the folder basename for suggestedName when the manifest has no name', () => {
    const inspection: PathInspection = { kind: 'icm', name: null, description: null };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes');
    expect(mode).toEqual({
      mode: 'adopt',
      originalPath: '/Users/mara/Documents/my-notes',
      suggestedName: 'my-notes',
      description: null
    });
  });

  it('falls back to the folder basename when the manifest name is blank/whitespace', () => {
    const inspection: PathInspection = { kind: 'icm', name: '   ', description: '' };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes');
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('my-notes');
    }
  });

  it('handles a trailing slash on the original path when computing the basename fallback', () => {
    const inspection: PathInspection = { kind: 'icm', name: null, description: null };
    const mode = decideOnboardingMode(inspection, '/Users/mara/Documents/my-notes/');
    expect(mode.mode).toBe('adopt');
    if (mode.mode === 'adopt') {
      expect(mode.suggestedName).toBe('my-notes');
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
