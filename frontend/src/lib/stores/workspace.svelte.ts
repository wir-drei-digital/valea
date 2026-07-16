import { api, type Api, type LiveSession } from '../api/client';
import { withBeforeMutate } from '../components/knowledge/before-mutate';

// id-based (C9, Phase 2) — no `path`; see `Valea.Api.Workspace`'s moduledoc.
export type RecentWorkspace = {
  id: string;
  name: string;
  lastOpenedAt?: string;
  [key: string]: unknown;
};

export type WorkspaceState = 'loading' | 'none' | 'open';

export type { LiveSession };

/**
 * Minimal surface of `api` this store depends on — lets the brief's test
 * inject a fake without implementing all 9 wrapped calls.
 */
type WorkspaceApi = Pick<
  Api,
  | 'getWorkspace'
  | 'recentWorkspaces'
  | 'createWorkspace'
  | 'openWorkspace'
  | 'adoptWorkspace'
  | 'workspaceSwitchPreflight'
>;

export class WorkspaceStore {
  state: WorkspaceState = $state('loading');
  name: string | null = $state(null);
  id: string | null = $state(null);
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
      this.id = null;
      this.generation = null;
      return;
    }

    const data = workspaceResult.data as {
      open: boolean;
      name: string | null;
      id: string | null;
      generation?: number | null;
    };
    if (data.open) {
      this.state = 'open';
      this.name = data.name;
      this.id = data.id;
      this.generation = data.generation ?? null;
    } else {
      this.state = 'none';
      this.name = null;
      this.id = null;
      this.generation = null;
    }
  }

  // NOTE (Phase 2, id-based create): `parentDir` is now ACCEPTED BUT
  // IGNORED — `create_workspace` is app-owned (Task 2.5); no caller
  // supplies a filesystem location anymore. Kept in the signature so both
  // Task 10.2/10.3 onboarding call sites (`onboarding-path.ts`'s
  // `startFresh`/`useExistingIcm`, wired from `CreateWorkspaceDialog.svelte`/
  // `OpenWorkspaceFlow.svelte`) keep compiling without a rework.
  async create(parentDir: string, name: string): Promise<{ ok: true } | { ok: false; error: string }> {
    void parentDir;
    const result = await this.#api.createWorkspace(name);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  // NOTE (Phase 2, id-based open): `id` was `path` pre-Task-2.5 — every
  // caller (`WorkspaceSwitcher`/`Onboarding.svelte`'s recent-workspace list —
  // the only two remaining callers as of Task 10.3, since onboarding's own
  // "Start fresh"/"Use existing ICM" paths call `create` above, not `open`)
  // now passes a workspace id string, not a filesystem path.
  async open(id: string): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.openWorkspace(id);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * ICM-aware onboarding (A-T16): adopts an existing, non-workspace
   * knowledge folder into a brand-new workspace BY MOVE — see
   * `Valea.Workspace.Adopt` on the backend. Mirrors `create`/`open` above:
   * only refreshes on success, so a rejected adopt (source already a
   * workspace, nested in one, a cycle, cross-device, ...) leaves the
   * store's current state untouched.
   *
   * UNUSED as of Task 10.3: `OpenWorkspaceFlow.svelte`'s move-adopt branch
   * (the one caller) was replaced by `useExistingIcm`'s mount-by-reference
   * flow — see `onboarding-path.ts`. Kept, not deleted: `Valea.Workspace.Adopt`
   * itself stays registered on the backend until Phase 11 deletes it, and
   * this wrapper is cheap to keep compiling alongside it.
   */
  async adopt(
    parentDir: string,
    name: string,
    icmSourcePath: string
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.adoptWorkspace(parentDir, name, icmSourcePath);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * Switches to a different workspace from inside an already-open one (the
   * sidebar's `WorkspaceSwitcher`), unlike `open()` above which is only ever
   * called from onboarding/`'none'` state.
   *
   * Task 10.1: runs `workspaceSwitchPreflight(id)` FIRST — if the
   * currently open workspace has live agent sessions a switch would stop,
   * `confirmLiveSessions` (the switcher's own confirmation dialog, awaited
   * for a yes/no) gets a chance to let the user bail before anything
   * actually switches. No `confirmLiveSessions` callback, or a `false`
   * resolution, aborts with `'cancelled'` — `open()` never runs. A
   * preflight RPC failure (e.g. an already-stale `id`) is NOT fatal here:
   * it's swallowed and the switch proceeds to `open()`, which surfaces
   * that same failure itself with a more specific error code.
   *
   * The currently open ICM page may hold an unflushed debounced edit —
   * reused directly (Task 21 brief: "the SAME exported hook the knowledge
   * route registered for pre-mutate flushes") is `withBeforeMutate`, the
   * exact helper `RenameDialog`/`DeleteDialog` already use to flush before
   * a tree mutation. `onBeforeMutate` is the route's `() => store.flush()`
   * (forwarded down through `Sidebar`/`WorkspaceSwitcher` as
   * `onBeforeMutateActive`), which throws `Error('unsaved_changes')` (see
   * `AppFrame`'s `onBeforeMutateActive` in the knowledge route) when the
   * flush leaves the page dirty with an error — caught here and surfaced
   * as the same `'unsaved_changes'` error code the rename/delete dialogs
   * already show, rather than losing the edit by switching out from under
   * it.
   *
   * On success, `open()`'s `refresh()` picks up the new workspace's
   * name/path/generation; the backend's `workspace` broadcast (Phase-1
   * machinery, wired once in the root layout via `wireIcmEvents`) also
   * resets `icmStore` for every open window/tab, not just this call site.
   */
  async switchTo(
    id: string,
    onBeforeMutate?: () => Promise<void>,
    confirmLiveSessions?: (sessions: LiveSession[]) => Promise<boolean>
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const preflight = await this.#api.workspaceSwitchPreflight(id);

    if (preflight.ok && preflight.data.liveSessions.length > 0) {
      const confirmed = confirmLiveSessions ? await confirmLiveSessions(preflight.data.liveSessions) : false;
      if (!confirmed) {
        return { ok: false, error: 'cancelled' };
      }
    }

    try {
      return await withBeforeMutate(onBeforeMutate, () => this.open(id));
    } catch {
      return { ok: false, error: 'unsaved_changes' };
    }
  }
}

export const workspaceStore = new WorkspaceStore(api);
