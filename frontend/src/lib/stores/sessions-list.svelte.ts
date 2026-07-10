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
}

export const sessionsListStore = new SessionsListStore(api);
