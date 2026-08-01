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

/**
 * The main nav shows at most this many sessions TOTAL across every project
 * group; anything beyond it lives behind the single "Show all" row (the
 * chat route's all-sessions pane, `/chat?all=1`).
 */
export const NAV_SESSIONS_TOTAL = 10;

export type IcmProjectGroup = {
  mountKey: string;
  /** The ICM's manifest display name (`MountSummary.name`), NOT the config key. */
  name: string;
  /** Non-null degraded reason (mirrors `MountSummary.degraded`) — a warning + Diagnose affordance, no new-session action. */
  degraded: string | null;
  /** This group's members of the workspace-wide `NAV_SESSIONS_TOTAL` most recently active sessions, most recent first. */
  sessions: AgentSessionSummary[];
  /** True when at least one of this ICM's sessions is live — forces the group's row open regardless of local collapse state. */
  hasLiveSession: boolean;
};

export type IcmProjectsView = {
  groups: IcmProjectGroup[];
  /** True when the workspace has MORE sessions than the nav shows — renders the single "Show all" row. */
  overflow: boolean;
};

/**
 * "Most recently active" ordering, shared by the sidebar groups and the
 * chat route's all-sessions pane: a live session IS current activity, so
 * live sorts before ended; within each half, newest `startedAt` first.
 */
export function compareByRecency(a: AgentSessionSummary, b: AgentSessionSummary): number {
  if (a.live !== b.live) return a.live ? -1 : 1;
  return (b.startedAt ?? '').localeCompare(a.startedAt ?? '');
}

/**
 * One row per ENABLED-or-DEGRADED ICM. A purely deactivated mount
 * (`enabled: false`, NOT degraded) is dropped entirely — it lives in
 * Workspace settings, not the sidebar.
 *
 * Sessions: the workspace-wide `NAV_SESSIONS_TOTAL` most recently active
 * sessions (per `compareByRecency`) are selected ACROSS groups, then each
 * group renders its own members of that set. Groups themselves order by
 * their most recently active session (a group whose newest session is
 * newer ranks higher); groups with no sessions at all sort last, keeping
 * `mounts`'s own config order among themselves.
 *
 * `recentGroups` (`recentSessionsStore.groups`) only carries an entry for
 * an ICM that has at least one session — an enabled/degraded mount absent
 * from it (brand new, or degraded with no session history) merges in with
 * an empty `sessions` array rather than being dropped. `overflow` is true
 * when more sessions exist than the nav displays (the store's
 * `NAV_SESSIONS_TOTAL + 1` per-group overflow-probe request makes the
 * count trustworthy for this comparison).
 */
export function orderGroups(mounts: MountSummary[], recentGroups: RecentSessionGroup[]): IcmProjectsView {
  const sessionsByMount = new Map(recentGroups.map((g) => [g.mountKey, g.sessions]));

  const base = mounts
    .filter((m) => m.enabled || m.degraded !== null)
    .map((m, configIndex) => ({
      mount: m,
      configIndex,
      all: [...(sessionsByMount.get(m.mountKey) ?? [])].sort(compareByRecency)
    }));

  const ranked = base
    .flatMap(({ mount, all }) => all.map((session) => ({ mountKey: mount.mountKey, session })))
    .sort((a, b) => compareByRecency(a.session, b.session));

  const visibleIds = new Set(ranked.slice(0, NAV_SESSIONS_TOTAL).map((r) => r.session.id));

  // A group's rank = the position of its most recently active session in
  // the workspace-wide ranking; session-less groups rank last (Infinity).
  const groupRank = new Map<string, number>();
  ranked.forEach((r, i) => {
    if (!groupRank.has(r.mountKey)) groupRank.set(r.mountKey, i);
  });

  const groups = base
    .map(({ mount, configIndex, all }) => ({
      configIndex,
      group: {
        mountKey: mount.mountKey,
        name: mount.name,
        degraded: mount.degraded,
        sessions: all.filter((s) => visibleIds.has(s.id)),
        hasLiveSession: all.some((s) => s.live)
      }
    }))
    .sort((a, b) => {
      const ra = groupRank.get(a.group.mountKey) ?? Infinity;
      const rb = groupRank.get(b.group.mountKey) ?? Infinity;
      if (ra !== rb) return ra - rb;
      return a.configIndex - b.configIndex;
    })
    .map((entry) => entry.group);

  return { groups, overflow: ranked.length > NAV_SESSIONS_TOTAL };
}

export type AllSessionsGroup = {
  mountKey: string;
  name: string;
  sessions: AgentSessionSummary[];
};

/**
 * The chat route's all-sessions pane: EVERY session (`sessionsList`'s flat
 * feed, whose summaries carry `icmMount`/`icmName`), grouped by project and
 * ordered by the same recency rule the sidebar uses — groups by their most
 * recently active session, sessions within a group most recent first. A
 * summary with no ICM identity (shouldn't happen post-clean-cut, but the
 * fields are nullable) buckets under its mount key fallback.
 */
export function groupAllSessions(sessions: AgentSessionSummary[]): AllSessionsGroup[] {
  const byMount = new Map<string, { name: string; sessions: AgentSessionSummary[] }>();

  for (const session of sessions) {
    const key = session.icmMount ?? '(unknown project)';
    const entry = byMount.get(key) ?? { name: session.icmName ?? key, sessions: [] };
    entry.sessions.push(session);
    byMount.set(key, entry);
  }

  return [...byMount.entries()]
    .map(([mountKey, entry]) => ({
      mountKey,
      name: entry.name,
      sessions: [...entry.sessions].sort(compareByRecency)
    }))
    .sort((a, b) => compareByRecency(a.sessions[0], b.sessions[0]));
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

/** The one git offer that exists today (git-sync spec §Implementation amendments 6). */
export const VALEA_GITIGNORE_OFFER = 'valea_gitignore';

/**
 * Does this ICM's row earn the ".valea/ → .gitignore" card? Two conditions,
 * both from state already on screen:
 *
 *  - the engine says this repo does NOT ignore `.valea` — and `null` there
 *    means "not asked" (an `off`-mode ICM, a folder that is no repo, a repo
 *    git could not answer for), which is never an offer;
 *  - the user has not waved this offer away for this mount, which is durable
 *    backend state (`MountSummary.gitOffersDismissed`), not a session flag.
 *
 * A `false` survives even when the ignore LINE is already present: git reads
 * a tracked `.valea` as not-ignored, and that repo still needs the untracking
 * half the card performs.
 */
export function offersValeaGitignore(
  repo: { valeaIgnored: boolean | null } | null,
  mount: Pick<MountSummary, 'gitOffersDismissed'> | undefined
): boolean {
  if (!repo || repo.valeaIgnored !== false) return false;
  return !(mount?.gitOffersDismissed ?? []).includes(VALEA_GITIGNORE_OFFER);
}

/**
 * What clicking the ICM row's git icon does. A repo that needs a human opens
 * the panel (where the resolve handoff lives); anything else just runs a
 * pass. The icon is one control with two meanings, and this is where the
 * meaning is decided.
 */
export function gitIconAction(signal: { attention: boolean }): 'open-panel' | 'sync-now' {
  return signal.attention ? 'open-panel' : 'sync-now';
}

/**
 * A session row's display title. Lifted out of the chat route's all-sessions
 * pane (and duplicated verbatim in `IcmProjects.svelte`) so the pane that
 * moved into `ChatPane` did not take a third inline copy with it.
 *
 * An untitled WORKFLOW run says so plainly rather than repeating its file
 * path: the path renders as its own mono line under the title, and a title
 * that is the line below it is just noise.
 */
export function sessionTitle(session: Pick<AgentSessionSummary, 'title' | 'kind'>): string {
  if (session.title && session.title.trim().length > 0) return session.title;
  if (session.kind === 'workflow') return 'Workflow run';
  return 'Chat session';
}

/**
 * "2 hours ago" for a session timestamp, in the largest unit that still
 * reads as a number — seconds under a minute, then minutes, hours, days.
 * Empty string for a missing or unparseable timestamp, because a row with no
 * start time should show nothing rather than "Invalid Date".
 */
export function sessionRelativeTime(iso: string | null | undefined): string {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const deltaSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const abs = Math.abs(deltaSeconds);
  if (abs < 60) return rtf.format(deltaSeconds, 'second');
  if (abs < 3600) return rtf.format(Math.round(deltaSeconds / 60), 'minute');
  if (abs < 86400) return rtf.format(Math.round(deltaSeconds / 3600), 'hour');
  return rtf.format(Math.round(deltaSeconds / 86400), 'day');
}
