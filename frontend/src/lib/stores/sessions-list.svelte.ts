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
