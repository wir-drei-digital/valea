/**
 * Pure decision logic for the Phase 9 sidebar's "ICM project groups" —
 * mirrors `mount-sections.ts`'s "extract the logic, no component render
 * harness" convention. `IcmProjects.svelte` is presentational over this
 * module; every ordering/capping/expansion decision lives here so it's
 * unit-testable without a Svelte render harness (none exists in this repo).
 */

import type { MountSummary } from '$lib/stores/mounts.svelte';
import type { RecentSessionGroup } from '$lib/stores/recent-sessions.svelte';
import type { AgentSessionSummary } from '$lib/stores/sessions-list.svelte';

/** Spec §"ICM group behavior": up to five sessions per ICM row before "Show all…" takes over. */
export const SESSIONS_PER_GROUP = 5;

export type IcmProjectGroup = {
  mountKey: string;
  /** The ICM's manifest display name (`MountSummary.name`), NOT the config key. */
  name: string;
  /** Non-null degraded reason (mirrors `MountSummary.degraded`) — a warning + Diagnose affordance, no new-session action. */
  degraded: string | null;
  /** Capped at `SESSIONS_PER_GROUP`, live sessions first (then whatever order the backend/store already provided). */
  sessions: AgentSessionSummary[];
  /** True when this ICM has MORE than `SESSIONS_PER_GROUP` sessions — renders the "Show all…" row. */
  hasMore: boolean;
  /** True when at least one of this ICM's sessions is live — forces the group's row open regardless of local collapse state. */
  hasLiveSession: boolean;
};

/**
 * One row per ENABLED-or-DEGRADED ICM, in `mounts`'s own order (`list_icms`
 * — the workspace's `icms:` config order; see `Valea.Mounts.list/1`'s
 * moduledoc). A purely deactivated mount (`enabled: false`, NOT degraded) is
 * dropped entirely — it lives in Workspace settings, not the sidebar (same
 * "deactivated" bucket `classifyMounts` sorts mounts into in
 * `mount-sections.ts`, though this function doesn't reuse that helper
 * directly since it needs the group SHAPE, not just the bucket).
 *
 * `recentGroups` (`recentSessionsStore.groups`) only carries an entry for an
 * ICM that has at least one session (`Valea.Agents.
 * list_recent_sessions_by_icm/1`'s moduledoc) — an enabled/degraded mount
 * absent from it (brand new, or degraded with no session history) merges in
 * with an empty `sessions` array rather than being dropped.
 */
export function orderGroups(mounts: MountSummary[], recentGroups: RecentSessionGroup[]): IcmProjectGroup[] {
  const sessionsByMount = new Map(recentGroups.map((g) => [g.mountKey, g.sessions]));

  return mounts
    .filter((m) => m.enabled || m.degraded !== null)
    .map((m) => {
      const all = sessionsByMount.get(m.mountKey) ?? [];
      const live = all.filter((s) => s.live);
      const ended = all.filter((s) => !s.live);

      return {
        mountKey: m.mountKey,
        name: m.name,
        degraded: m.degraded,
        sessions: [...live, ...ended].slice(0, SESSIONS_PER_GROUP),
        hasMore: all.length > SESSIONS_PER_GROUP,
        hasLiveSession: live.length > 0
      };
    });
}

/**
 * Whether a group's session list renders expanded. The active ICM (the one
 * the current route is scoped to — `IcmProjects.svelte`'s `activeMountKey`
 * prop) is always expanded, and a live session forces its group open too
 * (so a running session is never hidden behind a collapsed row) — both
 * override `collapsed`, the caller's own local per-mount toggle state.
 * Absent from `collapsed` (never touched) defaults to expanded — collapsing
 * is an opt-in the user reaches for, not the resting state.
 */
export function isGroupExpanded(
  group: Pick<IcmProjectGroup, 'mountKey' | 'hasLiveSession'>,
  activeMountKey: string | null,
  collapsed: Record<string, boolean>
): boolean {
  if (group.mountKey === activeMountKey) return true;
  if (group.hasLiveSession) return true;
  return !collapsed[group.mountKey];
}

/**
 * Turns an `icm_doctor` result into the sidebar's one-line "Diagnose"
 * summary (`IcmProjects.svelte`'s kebab action). Fix wave, Finding 3: counts
 * every check whose status ISN'T `"ok"`, not just `"failed"` —
 * `Valea.Mounts.Doctor.run/1` also reports `"unknown"` for a warn-style
 * check (e.g. secrets_hygiene) or one skipped after an earlier check in its
 * own gate failed (see `MountsDoctorPanel.svelte`'s doc comment and
 * `normalizeMountsDoctorChecks` in `mount-sections.ts`, which defaults a
 * missing status to `"unknown"` the same way). Counting only `"failed"`
 * meant an `ok: false` result made entirely of `"unknown"` checks rendered
 * as "0 checks failed" — reading as healthy when it wasn't.
 */
export function diagnosisSummary(data: { ok: boolean; checks: Array<{ status?: string }> }): {
  ok: boolean;
  summary: string;
} {
  if (data.ok) return { ok: true, summary: 'All checks passed.' };

  const needsAttention = data.checks.filter((c) => c.status !== 'ok').length;
  return {
    ok: false,
    summary:
      needsAttention === 1
        ? '1 check needs attention.'
        : `${needsAttention} checks need attention.`
  };
}
