import { api, type Api } from '../api/client';
import { recentSessionsStore } from './recent-sessions.svelte';
import { workspaceStore } from './workspace.svelte';
import type { GitStatusPush } from '../socket';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as `MailStore`/`CalendarStore`, so tests inject a fake without
 * implementing every wrapped call.
 */
type GitApi = Pick<Api, 'gitStatus' | 'gitSyncNow' | 'setIcmGitSync' | 'startGitConflictSession'>;

/**
 * One repo's app-facing sync status — camelCased/typed from the raw
 * snake_case row `Valea.Git.Engine.public_rows/1` builds. THREE surfaces
 * deliver exactly this row (the `git_status` RPC, the `git_status` channel
 * push, and the cockpit payload's `git` block), which is why one normalizer
 * serves all three.
 *
 * `state` is left `string`, not a union: the backend's own `@type status`
 * makes no closed-set promise at the type level either, and `"syncing"` is
 * in the enum but never emitted by today's engine — nothing here may depend
 * on seeing it.
 *
 * `localSha`/`remoteSha` are the pair that gives a conflict its identity
 * (`{mountKey, localSha, remoteSha}` tells "the same conflict, still there"
 * from "a new one"); carried so a consumer can dedupe without a second RPC.
 */
export type GitRepoStatus = {
  mountKey: string;
  icmName: string;
  /** `'full' | 'pull' | 'off'` — the ICM's configured sync mode. */
  mode: string;
  state: string;
  /** Why a repo is `unsupported`/`off`, when git could say; `null` otherwise. */
  reason: string | null;
  branch: string | null;
  ahead: number;
  behind: number;
  dirty: boolean;
  localSha: string | null;
  remoteSha: string | null;
  lastSyncAt: string | null;
  lastError: string | null;
  /** The resolution session already recorded for this conflict — the "Open session" case. */
  conflictSessionId: string | null;
};

/**
 * The three AGENT-ACTIONABLE states (spec §Conflict notices): each earns an
 * attention row on Today, the sidebar dot, and the Resolve button. Fetch,
 * push and auth failures are deliberately NOT here — those are `error`,
 * which is doctor material, not something to interrupt anyone with.
 *
 * Kept beside `gitAttentionText` on purpose: "which states raise a row" and
 * "what that row says" are one decision, and splitting them across modules
 * is how the two drift apart.
 */
export const GIT_ATTENTION_STATES = ['diverged', 'blocked_local', 'merge_in_progress'] as const;

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

/** Non-numeric raw input degrades to 0 rather than propagating `NaN` (same stance as `today/cockpit.ts`). */
function num(v: unknown): number {
  return typeof v === 'number' && Number.isFinite(v) ? v : 0;
}

function pick(raw: Record<string, unknown>, snake: string, camel: string): unknown {
  return raw[snake] !== undefined ? raw[snake] : raw[camel];
}

/**
 * Narrows one raw row. Snake keys are the real wire spelling; camel is
 * tolerated anyway (the `pick()` dual-read stance `today/cockpit.ts` takes
 * toward the generic-action map boundary — the extraction layer renames
 * fields of some shapes and not others, and this row must survive either).
 *
 * A row with no `mount_key` or no `state` is DROPPED: it could not be
 * addressed (every action is keyed by mount) nor classified.
 */
export function normalizeGitRepoStatus(raw: unknown): GitRepoStatus | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const rec = raw as Record<string, unknown>;

  const mountKey = str(pick(rec, 'mount_key', 'mountKey'));
  const state = str(rec.state);
  if (mountKey === null || mountKey === '' || state === null || state === '') return null;

  return {
    mountKey,
    icmName: str(pick(rec, 'icm_name', 'icmName')) ?? '',
    mode: str(rec.mode) ?? 'off',
    state,
    reason: str(rec.reason),
    branch: str(rec.branch),
    ahead: num(rec.ahead),
    behind: num(rec.behind),
    dirty: rec.dirty === true,
    localSha: str(pick(rec, 'local_sha', 'localSha')),
    remoteSha: str(pick(rec, 'remote_sha', 'remoteSha')),
    lastSyncAt: str(pick(rec, 'last_sync_at', 'lastSyncAt')),
    lastError: str(pick(rec, 'last_error', 'lastError')),
    conflictSessionId: str(pick(rec, 'conflict_session_id', 'conflictSessionId'))
  };
}

/** Every row of a `repos`/`git` array that survives normalization, sorted by mount key. */
export function normalizeGitRepoRows(raw: unknown): GitRepoStatus[] {
  return (Array.isArray(raw) ? raw : [])
    .map(normalizeGitRepoStatus)
    .filter((row): row is GitRepoStatus => row !== null)
    .sort((a, b) => a.mountKey.localeCompare(b.mountKey));
}

/** One repo's state as a human word — the modal's status line and the badge's title. */
export function gitStateLabel(state: string): string {
  switch (state) {
    case 'ok':
      return 'In sync';
    // In the backend enum but never emitted by today's engine — labelled for
    // completeness, depended on by nothing.
    case 'syncing':
      return 'Syncing';
    case 'diverged':
      return 'Diverged';
    case 'blocked_local':
      return 'Blocked by local edits';
    case 'merge_in_progress':
      return 'Merge in progress';
    case 'error':
      return 'Last sync failed';
    case 'off':
      return 'Sync off';
    case 'detached':
      return 'Detached HEAD';
    case 'no_upstream':
      return 'No upstream branch';
    case 'unsupported':
      return 'Not a syncable repository';
    default:
      return state;
  }
}

/**
 * One attention row's sentence: what happened, in the user's words, named by
 * ICM. The three agent-actionable states get purpose-written copy; anything
 * else falls back to the row's own `reason` (git's explanation) and then to
 * the bare state, so a state added backend-side still reads as something
 * rather than vanishing.
 */
export function gitAttentionText(repo: GitRepoStatus): string {
  const name = repo.icmName || repo.mountKey;
  switch (repo.state) {
    case 'diverged':
      return `${name}: local and remote diverged (${repo.ahead} ahead / ${repo.behind} behind)`;
    case 'blocked_local':
      return `${name}: local edits block sync`;
    case 'merge_in_progress':
      return `${name}: unfinished merge in the working tree`;
    default:
      return `${name}: ${repo.reason ?? repo.state}`;
  }
}

/**
 * What to show the user for a failed git RPC.
 *
 * `Valea.Api.Git`'s `error_for/1` answers git-specific failures with FINISHED
 * HUMAN SENTENCES in `type` (there are no stable machine codes for them), so
 * the default branch passes the string through untouched — never re-worded,
 * never matched on. Only the SHARED codes every RPC in the app can return are
 * translated here, exactly as `IcmProjects.svelte`'s `startSessionErrorMessage`
 * does for session starts.
 */
export function gitErrorMessage(error: string): string {
  switch (error) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'icm_unavailable':
      return "That ICM isn't available right now.";
    case 'harness_unavailable':
      return "The assistant isn't ready yet. Check Chat for details.";
    case 'channel_timeout':
    case 'unknown_error':
      return 'Something went wrong. Please try again.';
    default:
      return error;
  }
}

/**
 * Live view of every git-capable ICM's sync state: the sidebar badge, the
 * Today attention rows and the per-ICM modal all read THIS, never their own
 * copy, so the three can never disagree about a repo.
 *
 * Three feeds, one policy (`applyRows`):
 *  - `refresh()` — the `git_status` RPC, on cold load and on workspace switch
 *    (`refreshSidebarProjectStores`, icm.svelte.ts);
 *  - `handleGitStatus()` — the `git_status` push, every engine pass after that;
 *  - `applyRows()` — the cockpit payload's `git` block, whenever Today refetches.
 */
export class GitStore {
  repos: GitRepoStatus[] = $state([]);

  #api: GitApi;

  constructor(api: GitApi) {
    this.#api = api;
  }

  /** The rows that earn an attention row / badge, in mount-key order. */
  get attentionRepos(): GitRepoStatus[] {
    return this.repos.filter((repo) =>
      (GIT_ATTENTION_STATES as readonly string[]).includes(repo.state)
    );
  }

  byMountKey(mountKey: string): GitRepoStatus | null {
    return this.repos.find((repo) => repo.mountKey === mountKey) ?? null;
  }

  attention(mountKey: string): boolean {
    const repo = this.byMountKey(mountKey);
    return repo !== null && (GIT_ATTENTION_STATES as readonly string[]).includes(repo.state);
  }

  /**
   * Replaces the rows — EXCEPT when the payload is empty.
   *
   * BUSY-ENGINE CAVEAT (ledgered): while `Valea.Git.Engine` is mid-pass, the
   * status read can briefly answer with no rows at all, on the RPC, the push
   * and the cockpit block alike. Blanking the sidebar and Today for that
   * window — and then flickering them back a second later — is worse than
   * being one pass stale, so an empty payload is read as "nothing new to
   * say". The cost is bounded and named: the LAST git repo leaving a
   * workspace (unmounted, or its `sync:` set to something with no rows) keeps
   * its stale row until the next non-empty payload or a `reset()`. A
   * workspace close/switch calls `reset()` (`handleWorkspaceEvent`), which is
   * the case that actually matters.
   */
  applyRows(rows: GitRepoStatus[]): void {
    if (rows.length === 0) return;
    this.repos = [...rows].sort((a, b) => a.mountKey.localeCompare(b.mountKey));
  }

  /** Drops every row — the workspace they described is closing or being switched away from. */
  reset(): void {
    this.repos = [];
  }

  async refresh(generation?: number): Promise<void> {
    const gen = generation ?? workspaceStore.generation ?? 0;
    const result = await this.#api.gitStatus(gen);
    // A failed read (stale generation, no workspace, engine down) keeps the
    // last good rows — same posture as every other push-backed store here.
    if (!result.ok) return;
    this.applyRows(normalizeGitRepoRows((result.data as { repos?: unknown }).repos));
  }

  /** `git_status` push — the engine finished a pass over the whole workspace. */
  handleGitStatus(payload: GitStatusPush): void {
    this.applyRows(normalizeGitRepoRows(payload?.repos));
  }

  /**
   * "Sync now" — starts a pass and clears that repo's backoff (the one way
   * past a retry window). Answers as soon as the pass is STARTED; the result
   * arrives later as a `git_status` push.
   */
  async syncNow(mountKey: string, generation: number): Promise<string | null> {
    const result = await this.#api.gitSyncNow(mountKey, generation);
    return result.ok ? null : gitErrorMessage(result.error);
  }

  /** Writes the ICM's `sync:` mode (`full` | `pull` | `off`) and re-reads the rows. */
  async setMode(mountKey: string, mode: string, generation: number): Promise<string | null> {
    const result = await this.#api.setIcmGitSync(mountKey, mode, generation);
    if (!result.ok) return gitErrorMessage(result.error);
    // The backend broadcasts `{:mounts_changed}`, which triggers a pass — but
    // the mode itself is already true, and waiting a whole pass to show it
    // would read as the toggle not having worked.
    await this.refresh(generation);
    return null;
  }

  /**
   * Claims this repo's conflict and starts (or re-uses) the resolution
   * session. The claim is atomic backend-side, so a double-click is routed
   * to the FIRST click's session (`routed: 'existing'`) rather than starting
   * a rival resolver.
   *
   * On failure the rows are refreshed: the most likely failure by far is "the
   * conflict just cleared", and the attention row that prompted the click
   * should disappear rather than sit there rejecting clicks.
   */
  async startConflictSession(
    mountKey: string,
    generation: number
  ): Promise<{ ok: true; sessionId: string; routed: string } | { ok: false; error: string }> {
    const result = await this.#api.startGitConflictSession(mountKey, generation);
    if (!result.ok) {
      await this.refresh(generation);
      return { ok: false, error: gitErrorMessage(result.error) };
    }
    const data = result.data as { sessionId?: string; routed?: string };
    return { ok: true, sessionId: data.sessionId ?? '', routed: data.routed ?? 'new' };
  }
}

export const gitStore = new GitStore(api);

/**
 * THE Resolve/Open handler, shared by Today and the per-ICM modal so the
 * sequence exists once: a recorded session is opened directly (no RPC at
 * all), otherwise one is started and the sidebar's session list is refreshed
 * BEFORE navigating — no push fires for "a session was just created" (see
 * `wireRecentSessionsEvents`'s doc comment in `recent-sessions.svelte.ts`),
 * so without this the new session would be missing from the group the user
 * lands in.
 *
 * Navigation itself stays with the caller: `goto` belongs to the component,
 * and keeping it out here is what makes this testable.
 */
export async function resolveGitConflict(
  repo: GitRepoStatus,
  generation: number
): Promise<{ ok: true; sessionId: string } | { ok: false; error: string }> {
  if (repo.conflictSessionId) return { ok: true, sessionId: repo.conflictSessionId };

  const result = await gitStore.startConflictSession(repo.mountKey, generation);
  if (!result.ok) return result;

  void recentSessionsStore.refresh();
  return { ok: true, sessionId: result.sessionId };
}

let gitEventsWired = false;

/**
 * Attaches the `git_status` handler to the already-joined `workspace:events`
 * channel — SINGLE CALL SITE: wired from `wireIcmEvents` (`icm.svelte.ts`)
 * beside `wireMailEvents`/`wireCalendarEvents`, for the same
 * one-join-per-topic reason (Phoenix delivers a push to the ONE client-side
 * channel whose `join_ref` matches). Idempotent against repeat calls.
 */
export function wireGitEvents(channel: Channel): void {
  if (gitEventsWired) return;
  gitEventsWired = true;

  channel.on('git_status', (payload: GitStatusPush) => gitStore.handleGitStatus(payload));
}
