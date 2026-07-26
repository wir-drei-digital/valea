import { describe, expect, it } from 'vitest';
import { mostRecentMountKey } from './quick-session';

const session = (id: string, startedAt: string | null) => ({
  id,
  kind: 'chat',
  status: 'ended',
  live: false,
  startedAt
});

describe('mostRecentMountKey', () => {
  it('returns the fallback when no group has any session', () => {
    expect(mostRecentMountKey([], 'first-mount')).toBe('first-mount');
    expect(mostRecentMountKey([{ mountKey: 'a', sessions: [] }], 'first-mount')).toBe('first-mount');
    expect(mostRecentMountKey([], null)).toBeNull();
  });

  it('picks the group owning the newest session across groups', () => {
    const groups = [
      { mountKey: 'coaching', sessions: [session('s1', '2026-07-20T10:00:00Z')] },
      {
        mountKey: 'legal',
        sessions: [session('s2', '2026-07-26T09:00:00Z'), session('s3', '2026-07-01T09:00:00Z')]
      }
    ];
    expect(mostRecentMountKey(groups, null)).toBe('legal');
  });

  it('treats a missing startedAt as oldest rather than skipping the group', () => {
    const groups = [
      { mountKey: 'a', sessions: [session('s1', null)] },
      { mountKey: 'b', sessions: [session('s2', '2026-07-26T09:00:00Z')] }
    ];
    expect(mostRecentMountKey(groups, null)).toBe('b');
    expect(mostRecentMountKey([{ mountKey: 'only', sessions: [session('s1', null)] }], null)).toBe('only');
  });
});
