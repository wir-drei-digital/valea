import { describe, it, expect } from 'vitest';
import { parentPath } from './parent-path';

describe('parentPath', () => {
  it('derives the parent of a nested workspace-relative (embedded mount) page path', () => {
    expect(parentPath('mounts/primary/Workflows/Onboarding.md')).toBe('mounts/primary/Workflows');
  });

  it('derives the parent of a top-level embedded page (mount root as parent)', () => {
    expect(parentPath('mounts/primary/Onboarding.md')).toBe('mounts/primary');
  });

  it('derives the parent of a nested ABSOLUTE external page path, preserving the leading slash (A2-T5b)', () => {
    expect(parentPath('/Users/dana/Client Docs/Workflows/Onboarding.md')).toBe(
      '/Users/dana/Client Docs/Workflows'
    );
  });

  it('derives the parent of a page directly at an external mount root, still absolute', () => {
    expect(parentPath('/Users/dana/Client Docs/Onboarding.md')).toBe('/Users/dana/Client Docs');
  });

  it('returns an empty string for a bare (no-parent) relative path', () => {
    expect(parentPath('Onboarding.md')).toBe('');
  });
});
