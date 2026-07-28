import { describe, it, expect } from 'vitest';
import {
  orderGroups,
  groupAllSessions,
  isGroupExpanded,
  diagnosisSummary,
  NAV_SESSIONS_TOTAL
} from './icm-projects';
import type { MountSummary } from '$lib/stores/mounts.svelte';
import type { RecentSessionGroup } from '$lib/stores/recent-sessions.svelte';
import type { AgentSessionSummary } from '$lib/stores/sessions-list.svelte';

function mount(overrides: Partial<MountSummary> = {}): MountSummary {
  return {
    mountKey: 'primary',
    id: '11111111-1111-1111-1111-111111111111',
    name: 'Primary',
    description: 'The default mount',
    root: '/ws/primary',
    enabled: true,
    degraded: null,
    ...overrides
  };
}

function session(overrides: Partial<AgentSessionSummary> = {}): AgentSessionSummary {
  return {
    id: 's1',
    kind: 'chat',
    title: 'Session',
    workflow: null,
    runId: null,
    startedAt: '2026-07-14T10:00:00Z',
    status: 'running',
    live: false,
    busy: false,
    ...overrides
  };
}

describe('orderGroups', () => {
  it('drops a disabled, non-degraded mount — it lives in Workspace settings, not here', () => {
    const mounts = [mount({ mountKey: 'primary' }), mount({ mountKey: 'off', enabled: false, degraded: null })];

    const { groups } = orderGroups(mounts, []);

    expect(groups.map((g) => g.mountKey)).toEqual(['primary']);
  });

  it('orders groups by most recently active session; session-less groups sort last in config order', () => {
    const mounts = [mount({ mountKey: 'zeta' }), mount({ mountKey: 'alpha' }), mount({ mountKey: 'beta' })];
    const recent: RecentSessionGroup[] = [
      { mountKey: 'alpha', icmName: 'Alpha', sessions: [session({ id: 'older', startedAt: '2026-07-10' })] },
      { mountKey: 'beta', icmName: 'Beta', sessions: [session({ id: 'newer', startedAt: '2026-07-15' })] }
    ];

    const { groups } = orderGroups(mounts, recent);

    expect(groups.map((g) => g.mountKey)).toEqual(['beta', 'alpha', 'zeta']);
  });

  it('a live session counts as the most recent activity for its group', () => {
    const mounts = [mount({ mountKey: 'ended-newer' }), mount({ mountKey: 'live-older' })];
    const recent: RecentSessionGroup[] = [
      {
        mountKey: 'ended-newer',
        icmName: 'A',
        sessions: [session({ id: 'e', startedAt: '2026-07-20', live: false })]
      },
      {
        mountKey: 'live-older',
        icmName: 'B',
        sessions: [session({ id: 'l', startedAt: '2026-07-01', live: true })]
      }
    ];

    const { groups } = orderGroups(mounts, recent);

    expect(groups.map((g) => g.mountKey)).toEqual(['live-older', 'ended-newer']);
  });

  it('merges a degraded mount in with an empty sessions list when it has none yet', () => {
    const mounts = [mount({ mountKey: 'broken', name: 'Broken ICM', enabled: false, degraded: 'icm.yaml is missing' })];

    const { groups } = orderGroups(mounts, []);

    expect(groups).toEqual([
      {
        mountKey: 'broken',
        name: 'Broken ICM',
        degraded: 'icm.yaml is missing',
        sessions: [],
        hasLiveSession: false
      }
    ]);
  });

  it('caps DISPLAYED sessions at NAV_SESSIONS_TOTAL across every group, keeping the most recent ones', () => {
    const older = Array.from({ length: 8 }, (_, i) =>
      session({ id: `a-${i}`, startedAt: `2026-07-0${i + 1}` })
    );
    const newer = Array.from({ length: 8 }, (_, i) =>
      session({ id: `b-${i}`, startedAt: `2026-07-1${i + 1}` })
    );
    const mounts = [mount({ mountKey: 'a' }), mount({ mountKey: 'b' })];
    const recent: RecentSessionGroup[] = [
      { mountKey: 'a', icmName: 'A', sessions: older },
      { mountKey: 'b', icmName: 'B', sessions: newer }
    ];

    const { groups, overflow } = orderGroups(mounts, recent);
    const shown = groups.flatMap((g) => g.sessions);

    expect(shown).toHaveLength(NAV_SESSIONS_TOTAL);
    expect(overflow).toBe(true);
    // All 8 of the newer group made the cut; only the 2 newest of the older did.
    expect(groups[0].mountKey).toBe('b');
    expect(groups[0].sessions).toHaveLength(8);
    expect(groups[1].sessions.map((s) => s.id)).toEqual(['a-7', 'a-6']);
  });

  it('reports no overflow when everything fits', () => {
    const mounts = [mount({ mountKey: 'a' })];
    const recent: RecentSessionGroup[] = [
      { mountKey: 'a', icmName: 'A', sessions: [session({ id: 's1' })] }
    ];

    expect(orderGroups(mounts, recent).overflow).toBe(false);
  });
});

describe('groupAllSessions', () => {
  it('groups by icmMount with icmName as the label, both navs’ recency order', () => {
    const sessions = [
      session({ id: 'o1', startedAt: '2026-07-10', icmMount: 'one', icmName: 'One' }),
      session({ id: 't1', startedAt: '2026-07-20', icmMount: 'two', icmName: 'Two' }),
      session({ id: 'o2', startedAt: '2026-07-15', icmMount: 'one', icmName: 'One' }),
      session({ id: 'o3', startedAt: '2026-07-01', icmMount: 'one', icmName: 'One', live: true })
    ];

    const groups = groupAllSessions(sessions);

    // 'one' has a LIVE session → most recently active group despite older dates.
    expect(groups.map((g) => g.mountKey)).toEqual(['one', 'two']);
    expect(groups[0].name).toBe('One');
    expect(groups[0].sessions.map((s) => s.id)).toEqual(['o3', 'o2', 'o1']);
  });

  it('buckets a summary with no ICM identity under a fallback key', () => {
    const groups = groupAllSessions([session({ id: 'x', icmMount: null, icmName: null })]);
    expect(groups).toHaveLength(1);
    expect(groups[0].sessions[0].id).toBe('x');
  });
});

describe('isGroupExpanded', () => {
  it('is always true for the active ICM group, even when locally collapsed', () => {
    expect(isGroupExpanded({ mountKey: 'primary', hasLiveSession: false }, 'primary', { primary: true })).toBe(true);
  });

  it('is always true when the group has a live session, even when locally collapsed', () => {
    expect(isGroupExpanded({ mountKey: 'clients', hasLiveSession: true }, null, { clients: true })).toBe(true);
  });

  it('defaults to expanded when no local collapse state has been recorded yet', () => {
    expect(isGroupExpanded({ mountKey: 'clients', hasLiveSession: false }, null, {})).toBe(true);
  });

  it('respects local collapse state for an inactive, non-live group', () => {
    expect(isGroupExpanded({ mountKey: 'clients', hasLiveSession: false }, null, { clients: true })).toBe(false);
  });
});

describe('diagnosisSummary', () => {
  it('reports "All checks passed." when ok, regardless of check contents', () => {
    expect(diagnosisSummary({ ok: true, checks: [{ status: 'ok' }] })).toEqual({
      ok: true,
      summary: 'All checks passed.'
    });
  });

  it('counts every non-"ok" check, not just "failed" — an all-"unknown" failure must not read as "0 checks failed"', () => {
    const data = { ok: false, checks: [{ status: 'ok' }, { status: 'unknown' }, { status: 'unknown' }] };

    expect(diagnosisSummary(data)).toEqual({
      ok: false,
      summary: '2 checks need attention.'
    });
  });

  it('also counts genuinely "failed" checks alongside "unknown" ones', () => {
    const data = { ok: false, checks: [{ status: 'failed' }, { status: 'unknown' }, { status: 'ok' }] };

    expect(diagnosisSummary(data)).toEqual({
      ok: false,
      summary: '2 checks need attention.'
    });
  });

  it('uses singular wording for exactly one non-ok check', () => {
    expect(diagnosisSummary({ ok: false, checks: [{ status: 'failed' }] })).toEqual({
      ok: false,
      summary: '1 check needs attention.'
    });
  });

  it('treats a missing status as non-ok (defensive — mirrors normalizeMountsDoctorChecks defaulting a missing status to "unknown")', () => {
    expect(diagnosisSummary({ ok: false, checks: [{}] })).toEqual({
      ok: false,
      summary: '1 check needs attention.'
    });
  });
});
