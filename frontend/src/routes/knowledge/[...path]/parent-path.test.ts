import { describe, it, expect } from 'vitest';
import { parentPath } from './parent-path';

describe('parentPath', () => {
  it('derives the parent of a nested ICM-relative page path', () => {
    expect(parentPath('Workflows/Onboarding.md')).toBe('Workflows');
  });

  it('derives the parent of a deeply nested ICM-relative page path', () => {
    expect(parentPath('Clients/Coaching/Onboarding.md')).toBe('Clients/Coaching');
  });

  it('returns an empty string for a bare (no-parent) top-level path', () => {
    expect(parentPath('Onboarding.md')).toBe('');
  });

  it('ignores a stray double slash rather than producing an empty segment', () => {
    expect(parentPath('Workflows//Onboarding.md')).toBe('Workflows');
  });
});
