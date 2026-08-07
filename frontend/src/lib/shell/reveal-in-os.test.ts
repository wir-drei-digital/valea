import { describe, it, expect } from 'vitest';
import { absPathFor } from './reveal-in-os';

const mounts = [
  { mountKey: 'work', root: '/Users/d/ICMs/Work' },
  { mountKey: 'life', root: '/Users/d/ICMs/Life/' }
];

describe('absPathFor', () => {
  it('joins the mount root with the ICM-relative path', () => {
    expect(absPathFor(mounts, 'work', 'Clients/acme.md')).toBe('/Users/d/ICMs/Work/Clients/acme.md');
  });

  it('does not double the separator when the root carries a trailing slash', () => {
    expect(absPathFor(mounts, 'life', 'notes.md')).toBe('/Users/d/ICMs/Life/notes.md');
  });

  it('answers the mount root itself for the empty path', () => {
    expect(absPathFor(mounts, 'work', '')).toBe('/Users/d/ICMs/Work');
  });

  it('returns null for an unknown mount, so the caller offers nothing rather than aiming at a wrong path', () => {
    expect(absPathFor(mounts, 'gone', 'notes.md')).toBeNull();
  });

  it('returns null for a mount with no resolved root', () => {
    expect(absPathFor([{ mountKey: 'broken', root: '' }], 'broken', 'a.md')).toBeNull();
  });

  it('returns null for a relPath carrying a .. segment, however deep', () => {
    expect(absPathFor(mounts, 'work', '../../etc')).toBeNull();
    expect(absPathFor(mounts, 'work', 'Clients/../../../etc/passwd')).toBeNull();
  });

  it('returns null for an absolute relPath', () => {
    expect(absPathFor(mounts, 'work', '/etc/passwd')).toBeNull();
  });

  it('allows a filename that merely contains dots, as long as no segment IS ..', () => {
    expect(absPathFor(mounts, 'work', '..notes.md')).toBe('/Users/d/ICMs/Work/..notes.md');
    expect(absPathFor(mounts, 'work', 'foo..bar')).toBe('/Users/d/ICMs/Work/foo..bar');
  });
});
