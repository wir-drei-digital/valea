import { api, type Api } from '../api/client';

/** Minimal surface of `api` this store depends on — same `Pick<Api, ...>` convention as the other T16 stores. */
type SessionsListApi = Pick<Api, 'listAgentSessions'>;

/** One row of `list_agent_sessions` — mirrors `listAgentSessionsFields` in `api/client.ts`. */
export type AgentSessionSummary = {
  id: string;
  kind: string;
  title?: string | null;
  workflow?: string | null;
  runId?: string | null;
  startedAt?: string | null;
  status: string;
  live: boolean;
  /** A turn is in flight right now (snapshot-fresh, like `live`) — the sidebar's "working" indicator. */
  busy: boolean;
  /** The session's primary-ICM identity snapshot (session/v1 metadata). */
  icmMount?: string | null;
  icmName?: string | null;
};

/**
 * Flat list of known agent sessions (live + ended), for a sessions/chat
 * sidebar. Deliberately dumb — no live updates, just `refresh()` on demand;
 * per-session live state is `AgentSessionStore`'s job once a session is
 * opened.
 */
export class SessionsListStore {
  sessions: AgentSessionSummary[] = $state([]);
  loaded = $state(false);
  /**
   * The all-sessions pane's "include scheduled runs" toggle (tasks+schedules
   * spec §Scheduled-session visibility). Default off: scheduled runs are reached
   * through the run history under their schedule, and one hourly schedule would
   * otherwise own this list.
   */
  includeScheduled = $state(false);

  #api: SessionsListApi;

  constructor(api: SessionsListApi) {
    this.#api = api;
  }

  async refresh(): Promise<void> {
    const result = await this.#api.listAgentSessions();
    if (!result.ok) return;

    const data = result.data as { sessions?: AgentSessionSummary[] };
    this.sessions = data.sessions ?? [];
    this.loaded = true;
  }

  /**
   * What the all-sessions pane renders — `sessions` minus scheduled runs unless
   * `includeScheduled` is set.
   *
   * The filter is CLIENT-side here, unlike the nav feed's (which passes
   * `include_scheduled` to `list_recent_sessions_by_icm` and is filtered
   * backend-side before its per-group limit). Two reasons, both about this
   * particular list:
   *
   *   1. `list_agent_sessions` — the flat, workspace-wide listing this store
   *      reads — carries no such argument, and it must not: it doubles as the
   *      TITLE INDEX for whatever transcript is open (`ChatView` looks the open
   *      session up in `sessions`), and a scheduled run reached from its
   *      schedule's run history is exactly such a transcript. Filtering it at
   *      the source would blank that title.
   *   2. There is no `limit` on this list, so hiding a row costs nothing —
   *      the spec's "never fetch-then-hide" rule exists because a limit applied
   *      before filtering would let scheduled runs eat the nav feed's slots.
   *
   * A summary with no `kind` is NOT scheduled — same rule as
   * `Valea.Agents.reject_scheduled/2`: name the one kind excluded, leave every
   * other transcript visible.
   */
  get visibleSessions(): AgentSessionSummary[] {
    return this.includeScheduled ? this.sessions : this.sessions.filter((s) => s.kind !== 'scheduled');
  }

  /** How many scheduled runs the toggle would reveal — the checkbox's own count. */
  get scheduledCount(): number {
    return this.sessions.filter((s) => s.kind === 'scheduled').length;
  }

  /**
   * Clears back to cold-start shape (empty `sessions`, `loaded` false) —
   * final review, I3: called from `handleWorkspaceEvent` in `icm.svelte.ts`
   * alongside its three peers, on every workspace event (close, open, or
   * switch), so the previous workspace's sessions are never mistaken for
   * the new one's. Mirrors `RecentSessionsStore.reset()` exactly.
   *
   * Needed once this store stopped being route-local: it used to be a
   * `new SessionsListStore(api)` inside `/chat`, disposed on unmount, so a
   * workspace switch could not outlive it. As a shared singleton (read by
   * the all-sessions pane and every `ChatView`) a user sitting on
   * `/chat?all=1` through a switch would otherwise keep the old list.
   */
  reset(): void {
    this.sessions = [];
    this.loaded = false;
  }
}

export const sessionsListStore = new SessionsListStore(api);
