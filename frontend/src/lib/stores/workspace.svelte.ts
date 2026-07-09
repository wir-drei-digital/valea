import { api, type Api } from '../api/client';

export type RecentWorkspace = {
  path: string;
  name: string;
  lastOpenedAt?: string;
  [key: string]: unknown;
};

export type WorkspaceState = 'loading' | 'none' | 'open';

/**
 * Minimal surface of `api` this store depends on — lets the brief's test
 * inject a fake without implementing all 8 wrapped calls.
 */
type WorkspaceApi = Pick<Api, 'getWorkspace' | 'recentWorkspaces' | 'createWorkspace' | 'openWorkspace'>;

export class WorkspaceStore {
  state: WorkspaceState = $state('loading');
  name: string | null = $state(null);
  path: string | null = $state(null);
  recent: RecentWorkspace[] = $state([]);

  #api: WorkspaceApi;

  constructor(api: WorkspaceApi) {
    this.#api = api;
  }

  async refresh(): Promise<void> {
    const [workspaceResult, recentResult] = await Promise.all([this.#api.getWorkspace(), this.#api.recentWorkspaces()]);

    if (recentResult.ok) {
      this.recent = recentResult.data as RecentWorkspace[];
    }

    if (!workspaceResult.ok) {
      this.state = 'none';
      this.name = null;
      this.path = null;
      return;
    }

    const data = workspaceResult.data as { open: boolean; name: string | null; path: string | null };
    if (data.open) {
      this.state = 'open';
      this.name = data.name;
      this.path = data.path;
    } else {
      this.state = 'none';
      this.name = null;
      this.path = null;
    }
  }

  async create(parentDir: string, name: string): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.createWorkspace(parentDir, name);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  async open(path: string): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.openWorkspace(path);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }
}

export const workspaceStore = new WorkspaceStore(api);
