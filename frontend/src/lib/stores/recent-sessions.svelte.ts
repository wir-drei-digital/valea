import type { Channel } from 'phoenix';
import { api, type Api } from '../api/client';
import type { AgentSessionSummary } from './sessions-list.svelte';

/** Minimal surface of `api` this store depends on — same `Pick<Api, ...>` convention as the other stores. */
type RecentSessionsApi = Pick<Api, 'listRecentSessionsByIcm'>;

/**
 * One row of `list_recent_sessions_by_icm`'s `groups` — mirrors
 * `listRecentSessionsByIcmFields` in `api/client.ts`. `sessions` is the same
 * trimmed shape `SessionsListStore` uses (`AgentSessionSummary` —
 * `Valea.Agents.trim_summary/1` server-side), already live-first/newest
 * ordered and capped at the requested limit by the backend
 * (`Valea.Agents.list_recent_sessions_by_icm/1`'s `build_group/3`) — this
 * store preserves that order rather than re-sorting.
 */
export type RecentSessionGroup = {
  mountKey: string;
  icmName: string;
  sessions: AgentSessionSummary[];
};

/**
 * Grouped-by-ICM recent-session feed for the Phase 9 sidebar's project
 * groups (Task 9.1) — mirrors `SessionsListStore`'s shape (`groups`/`loaded`,
 * a bare `refresh()`, no live per-session updates) and adds
 * `sessionsFor(mountKey)` so `IcmProjects` (Task 9.2) can look up one ICM's
 * recent sessions without re-scanning `groups` itself.
 *
 * Only ICMs with at least one session appear in `groups` — an
 * enabled/degraded mount with none yet is `icm-projects.ts`'s own concern to
 * merge in from `mountsStore.mounts` (see `Valea.Agents.
 * list_recent_sessions_by_icm/1`'s moduledoc).
 */
export class RecentSessionsStore {
  groups: RecentSessionGroup[] = $state([]);
  loaded = $state(false);

  #api: RecentSessionsApi;

  constructor(api: RecentSessionsApi) {
    this.#api = api;
  }

  /**
   * `limit` is always 5 here (spec §"ICM group behavior": up to five
   * sessions per ICM row) — explicit rather than relying on
   * `api.listRecentSessionsByIcm`'s own default so this store's contract
   * doesn't silently drift if that wrapper's default ever changes.
   */
  async refresh(): Promise<void> {
    const result = await this.#api.listRecentSessionsByIcm(5);
    if (!result.ok) return;

    const data = result.data as { groups?: RecentSessionGroup[] };
    this.groups = data.groups ?? [];
    this.loaded = true;
  }

  /** This ICM's recent sessions, server order preserved; `[]` when the ICM has none (or isn't in `groups` yet). */
  sessionsFor(mountKey: string): AgentSessionSummary[] {
    return this.groups.find((g) => g.mountKey === mountKey)?.sessions ?? [];
  }
}

export const recentSessionsStore = new RecentSessionsStore(api);

let recentSessionsEventsWired = false;

/**
 * Attaches a `mounts_changed` listener to an already-joined channel and
 * keeps `recentSessionsStore` fresh — same reason/pattern as
 * `wireMountsEvents`/`wireQueueEvents`/`wireAuditEvents`/`wireMailEvents`
 * (see their doc comments in `mounts.svelte.ts` etc.): Phoenix's JS client
 * only reliably delivers pushes to ONE join per topic per socket, so this
 * rides the single `workspace:events` join `wireIcmEvents` (`icm.svelte.ts`)
 * owns rather than opening a second one here.
 *
 * `mounts_changed` (not `icm_changed`) is the trigger named by the task
 * brief's spec note ("Refresh is triggered on workspace open, on
 * mounts_changed, and when a session's status changes") — a mount
 * enabling/disabling/mounting changes which ICMs the sidebar's project
 * groups cover. "Workspace open" is wired directly into `wireIcmEvents`'s
 * `onWorkspace` handler (alongside `icmStore.refetch()`), not here.
 *
 * "When a session's status changes" has NO workspace-level broadcast to
 * hook: `SessionServer`'s `{:session_status, status}` only rides the
 * per-session `agent_session:<id>` topic (`ValeaWeb.AgentSessionChannel`),
 * which `WorkspaceEventsChannel` never subscribes to — wiring a live push
 * for every open session's status into this store is a bigger change than
 * this task's scope (no backend changes expected here). In practice the one
 * in-scope moment that matters — a brand-new session just created from the
 * sidebar's `+` — is covered by the caller (`IcmProjects.svelte`) calling
 * `recentSessionsStore.refresh()` itself right after `createAgentSession`
 * succeeds, same as the existing `/chat` page does for `SessionsListStore`.
 *
 * Idempotent against repeat calls, same spirit as `wireMountsEvents` — a
 * second call is a no-op rather than attaching a second `mounts_changed`
 * handler (which would double-refresh).
 */
export function wireRecentSessionsEvents(channel: Channel): void {
  if (recentSessionsEventsWired) return;
  recentSessionsEventsWired = true;

  channel.on('mounts_changed', () => {
    void recentSessionsStore.refresh();
  });
}
