import { describe, it, expect } from 'vitest';
import { orderGroups, isGroupExpanded, diagnosisSummary, SESSIONS_PER_GROUP } from './icm-projects';
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
    ...overrides
  };
}

describe('orderGroups', () => {
  it('drops a disabled, non-degraded mount — it lives in Workspace settings, not here', () => {
    const mounts = [mount({ mountKey: 'primary' }), mount({ mountKey: 'off', enabled: false, degraded: null })];

    const groups = orderGroups(mounts, []);

    expect(groups.map((g) => g.mountKey)).toEqual(['primary']);
  });

  it('keeps config order — the order `mounts` itself arrives in, not session recency', () => {
    const mounts = [mount({ mountKey: 'zeta' }), mount({ mountKey: 'alpha' })];
    const recent: RecentSessionGroup[] = [
      { mountKey: 'alpha', icmName: 'Alpha', sessions: [session({ id: 'newer', startedAt: '2026-07-15' })] }
    ];

    const groups = orderGroups(mounts, recent);

    expect(groups.map((g) => g.mountKey)).toEqual(['zeta', 'alpha']);
  });

  it('merges a degraded mount in with an empty sessions list when it has none yet', () => {
    const mounts = [mount({ mountKey: 'broken', name: 'Broken ICM', enabled: false, degraded: 'icm.yaml is missing' })];

    const groups = orderGroups(mounts, []);

    expect(groups).toEqual([
      {
        mountKey: 'broken',
        name: 'Broken ICM',
        degraded: 'icm.yaml is missing',
        sessions: [],
        hasMore: false,
        hasLiveSession: false
      }
    ]);
  });

  it('caps sessions at 5, with live sessions ordered first', () => {
    const sessions = [
      session({ id: 'e1', live: false }),
      session({ id: 'e2', live: false }),
      session({ id: 'l1', live: true }),
      session({ id: 'e3', live: false }),
      session({ id: 'e4', live: false }),
      session({ id: 'e5', live: false })
    ];
    const mounts = [mount({ mountKey: 'primary' })];
    const recent: RecentSessionGroup[] = [{ mountKey: 'primary', icmName: 'Primary', sessions }];

    const groups = orderGroups(mounts, recent);

    expect(groups[0].sessions).toHaveLength(SESSIONS_PER_GROUP);
    expect(groups[0].sessions[0].id).toBe('l1');
    expect(groups[0].sessions.map((s) => s.id)).not.toContain('e5');
    expect(groups[0].hasLiveSession).toBe(true);
  });

  it('reports hasMore (Show all…) only when the RAW server response overflows the display cap — a 6-item response (the store\'s SESSIONS_PER_GROUP + 1 overflow-probe request) yields 5 displayed + hasMore, a 5-item response yields 5 displayed + no hasMore', () => {
    const exactlyFive = Array.from({ length: SESSIONS_PER_GROUP }, (_, i) => session({ id: `five-${i}` }));
    const overflowing = Array.from({ length: SESSIONS_PER_GROUP + 1 }, (_, i) => session({ id: `over-${i}` }));
    const mounts = [mount({ mountKey: 'exact' }), mount({ mountKey: 'over' })];
    const recent: RecentSessionGroup[] = [
      { mountKey: 'exact', icmName: 'Exact', sessions: exactlyFive },
      { mountKey: 'over', icmName: 'Over', sessions: overflowing }
    ];

    const groups = orderGroups(mounts, recent);
    const exact = groups.find((g) => g.mountKey === 'exact');
    const over = groups.find((g) => g.mountKey === 'over');

    expect(exact?.sessions).toHaveLength(SESSIONS_PER_GROUP);
    expect(exact?.hasMore).toBe(false);
    expect(over?.sessions).toHaveLength(SESSIONS_PER_GROUP);
    expect(over?.hasMore).toBe(true);
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
