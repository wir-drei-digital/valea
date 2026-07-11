import { api, type Api } from '../api/client';
import { withBeforeMutate } from '../components/knowledge/before-mutate';

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
  generation: number | null = $state(null);
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
      this.generation = null;
      return;
    }

    const data = workspaceResult.data as {
      open: boolean;
      name: string | null;
      path: string | null;
      generation?: number | null;
    };
    if (data.open) {
      this.state = 'open';
      this.name = data.name;
      this.path = data.path;
      this.generation = data.generation ?? null;
    } else {
      this.state = 'none';
      this.name = null;
      this.path = null;
      this.generation = null;
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

  /**
   * Switches to a different workspace from inside an already-open one (the
   * sidebar's `WorkspaceSwitcher`), unlike `open()` above which is only ever
   * called from onboarding/`'none'` state. The currently open ICM page may
   * hold an unflushed debounced edit — reused directly (Task 21 brief:
   * "the SAME exported hook the knowledge route registered for pre-mutate
   * flushes") is `withBeforeMutate`, the exact helper `RenameDialog`/
   * `DeleteDialog` already use to flush before a tree mutation. `onBeforeMutate`
   * is the route's `() => store.flush()` (forwarded down through
   * `Sidebar`/`WorkspaceSwitcher` as `onBeforeMutateActive`), which throws
   * `Error('unsaved_changes')` (see `AppFrame`'s `onBeforeMutateActive` in
   * the knowledge route) when the flush leaves the page dirty with an error —
   * caught here and surfaced as the same `'unsaved_changes'` error code the
   * rename/delete dialogs already show, rather than losing the edit by
   * switching out from under it.
   *
   * On success, `open()`'s `refresh()` picks up the new workspace's
   * name/path/generation; the backend's `workspace` broadcast (Phase-1
   * machinery, wired once in the root layout via `wireIcmEvents`) also
   * resets `icmStore` for every open window/tab, not just this call site.
   */
  async switchTo(
    path: string,
    onBeforeMutate?: () => Promise<void>
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    try {
      return await withBeforeMutate(onBeforeMutate, () => this.open(path));
    } catch {
      return { ok: false, error: 'unsaved_changes' };
    }
  }
}

export const workspaceStore = new WorkspaceStore(api);
