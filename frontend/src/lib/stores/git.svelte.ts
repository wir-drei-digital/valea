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
type GitApi = Pick<
  Api,
  | 'gitStatus'
  | 'gitSyncNow'
  | 'setIcmGitSync'
  | 'startGitConflictSession'
  | 'addValeaGitignore'
  | 'dismissGitOffer'
>;

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
  /**
   * Is Valea's own `.valea/` folder ignored / tracked in this repo?
   * `null` is "not asked" — a row for a repo the engine leaves alone
   * (`mode: 'off'`), or one git could not answer for — and is deliberately
   * NOT the same as `false`: only a `false` earns the offer card.
   */
  valeaIgnored: boolean | null;
  valeaTracked: boolean | null;
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

/**
 * How long a click-started sync may spin without a pass reporting back. A
 * backstop, not a schedule: passes normally land in well under a second, but
 * an engine that went away (workspace closed under the click, a fetch wedged
 * on a credential prompt) must not leave an icon spinning forever.
 */
export const SYNC_SPINNER_TIMEOUT_MS = 30_000;

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

/** Tri-state: anything that isn't a real boolean is "not asked", never "no". */
function bool(v: unknown): boolean | null {
  return typeof v === 'boolean' ? v : null;
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
    conflictSessionId: str(pick(rec, 'conflict_session_id', 'conflictSessionId')),
    valeaIgnored: bool(pick(rec, 'valea_ignored', 'valeaIgnored')),
    valeaTracked: bool(pick(rec, 'valea_tracked', 'valeaTracked'))
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
 * One repo's whole state as a single line — `main · 1 ahead / 2 behind ·
 * uncommitted changes` — for the ICM row's icon tooltip and aria-label.
 *
 * The state LABEL leads only when it is worth saying: an `ok` repo's headline
 * is its branch, while a held or failed one has to name what happened before
 * the details. Built here rather than exported from `GitSyncModal.svelte`,
 * whose version of this line is markup (four conditional `<span>`s) and not
 * a string anything else could reuse.
 */
export function gitStatusLine(repo: GitRepoStatus): string {
  const parts: string[] = [];
  if (repo.state !== 'ok') parts.push(gitStateLabel(repo.state));
  if (repo.branch) parts.push(repo.branch);
  if (repo.ahead > 0 || repo.behind > 0) parts.push(`${repo.ahead} ahead / ${repo.behind} behind`);
  if (repo.dirty) parts.push('uncommitted changes');
  return parts.join(' · ');
}

/**
 * What the ICM row's git icon has to render, derived from one repo row.
 *
 * `visible` is the quiet-unless-it-matters rule made explicit: a repo that is
 * level, clean and unheld shows nothing until the row is hovered. Everything
 * else — a hold, work to push, work to pull, an uncommitted tree — earns ink
 * of its own.
 */
export type GitRowSignal = {
  /** There is a row at all for this mount — the icon renders only then. */
  present: boolean;
  /** Worth showing without a hover. */
  visible: boolean;
  ahead: number;
  behind: number;
  dirty: boolean;
  /** One of the three agent-actionable holds — the icon opens the panel instead of syncing. */
  attention: boolean;
  /** A sync this client asked for, not a state the engine reports (it never emits one). */
  spinning: boolean;
};

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
 * TWO feeds, one install path (`#install`):
 *  - `refresh()` — the `git_status` RPC, on cold load and on workspace switch
 *    (`refreshSidebarProjectStores`, icm.svelte.ts);
 *  - `handleGitStatus()` — the `git_status` push, every engine pass after that.
 *
 * The cockpit payload's `git` block is deliberately NOT a third feed: it is
 * read from the same `Engine.statuses()` cache the RPC reads, so it can only
 * ever be as fresh or staler than these two, and a late cockpit reply
 * re-installing a conflict the newest pass had already cleared is exactly the
 * race the tokens below exist to stop. Cold load is covered by `refresh()`.
 *
 * ORDERING (both directions):
 *  - `#readToken` — identity of the LATEST STARTED read; an older read's reply
 *    can never install over a newer read's (the `CalendarStore.#fetchToken`
 *    pattern, and the reason it is a plain field: a `$state` object read back
 *    through the proxy fails identity comparison).
 *  - `#pushInstalls` — count of pushes that actually installed rows; a read
 *    that started before one of them is dropped, because the push is derived
 *    from a pass that finished LATER than the cache the read saw.
 */
export class GitStore {
  #rows: GitRepoStatus[] = $state([]);

  /**
   * Optimistic sync-mode overlay, per mount: what the user just chose, and
   * what the wire said before they chose it.
   *
   * Necessary because `set_icm_git_sync` writes the ICM's config and
   * broadcasts `{:mounts_changed}` — it does NOT update `Engine.statuses()`.
   * A row's `mode` is re-derived only inside a pass, and `git_status` reads
   * the LAST COMPLETED pass's cached map, so re-reading straight after a save
   * returns the OLD mode: the picker would visibly snap back to the previous
   * option (with "Sync now" still disabled) until a pass — including a
   * network fetch — finished.
   *
   * Held until the wire MOVES OFF `replaced`, not merely until it matches
   * `mode`: that clears on agreement (the normal case) and also self-heals if
   * the config was changed underneath us to some third value, instead of
   * pinning a lie on screen forever.
   */
  #pendingModes: Record<string, { mode: string; replaced: string }> = $state({});

  /**
   * Mounts whose icon is spinning because THIS client asked for a pass.
   *
   * Entirely client-side, and it has to be: the engine publishes one row per
   * pass and never emits a `syncing` state, so there is no wire signal for
   * "a pass is running" to render. A spin therefore means "your click was
   * accepted", and it ends the moment a pass installs rows (any pass — one
   * pass covers every mount) or, failing that, after
   * `SYNC_SPINNER_TIMEOUT_MS`, so a workspace that goes quiet cannot leave an
   * icon spinning forever.
   */
  #syncing: Record<string, boolean> = $state({});
  /** Not `$state`: timer handles are bookkeeping, nothing renders them. */
  #syncTimers: Record<string, ReturnType<typeof setTimeout>> = {};

  #api: GitApi;
  #readToken: object = {};
  #pushInstalls = 0;

  constructor(api: GitApi) {
    this.#api = api;
  }

  /** The installed rows with any optimistic mode choice laid over them. */
  get repos(): GitRepoStatus[] {
    const pending = this.#pendingModes;
    // Identity-stable in the overwhelmingly common case (no pending write),
    // so consumers deriving from this don't churn.
    if (Object.keys(pending).length === 0) return this.#rows;
    return this.#rows.map((row) =>
      pending[row.mountKey] ? { ...row, mode: pending[row.mountKey].mode } : row
    );
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
   * Everything the ICM row's git icon renders from, in one derivation — so
   * "when is it shown", "what colour" and "what does clicking do" are one
   * decision rather than three conditions spread across a template.
   */
  gitRowSignal(mountKey: string): GitRowSignal {
    const repo = this.byMountKey(mountKey);
    const spinning = this.#syncing[mountKey] === true;

    if (!repo) {
      return {
        present: false,
        visible: false,
        ahead: 0,
        behind: 0,
        dirty: false,
        attention: false,
        spinning
      };
    }

    const attention = (GIT_ATTENTION_STATES as readonly string[]).includes(repo.state);

    return {
      present: true,
      visible: attention || repo.ahead > 0 || repo.behind > 0 || repo.dirty,
      ahead: repo.ahead,
      behind: repo.behind,
      dirty: repo.dirty,
      attention,
      spinning
    };
  }

  /**
   * Drops every row and every pending mode — the workspace they described is
   * closing or being switched away from — and invalidates any read still in
   * flight, so the outgoing workspace's reply cannot land after the reset.
   */
  reset(): void {
    this.#rows = [];
    this.#pendingModes = {};
    this.#readToken = {};
    for (const key of Object.keys(this.#syncTimers)) clearTimeout(this.#syncTimers[key]);
    this.#syncTimers = {};
    this.#syncing = {};
  }

  async refresh(generation?: number): Promise<void> {
    const gen = generation ?? workspaceStore.generation ?? 0;

    const token = {};
    this.#readToken = token;
    const pushesAtStart = this.#pushInstalls;

    const result = await this.#api.gitStatus(gen);
    // A failed read (stale generation, no workspace, engine down) keeps the
    // last good rows — same posture as every other push-backed store here.
    if (!result.ok) return;
    // Superseded: either a newer read started, or a push installed rows this
    // reply cannot know about (its `Engine.statuses()` snapshot predates the
    // pass that pushed). Both mean this answer is the older truth.
    if (this.#readToken !== token || this.#pushInstalls !== pushesAtStart) return;

    this.#install(normalizeGitRepoRows((result.data as { repos?: unknown }).repos));
  }

  /**
   * `git_status` push — the engine finished a pass over the whole workspace.
   * Always wins over any read already in flight (see `#pushInstalls`).
   */
  handleGitStatus(payload: GitStatusPush): void {
    const installed = this.#install(normalizeGitRepoRows(payload?.repos));
    if (installed) this.#pushInstalls += 1;
  }

  /**
   * Replaces the rows — EXCEPT when the payload is empty. Answers whether it
   * actually installed anything.
   *
   * BUSY-ENGINE CAVEAT (ledgered): while `Valea.Git.Engine` is mid-pass, the
   * status read can briefly answer with no rows at all, on the RPC and the
   * push alike. Blanking the sidebar and Today for that window — and then
   * flickering them back a second later — is worse than being one pass stale,
   * so an empty payload is read as "nothing new to say", and (since nothing
   * was learned) it does not supersede a read in flight either. The cost is
   * bounded and named: the LAST git repo leaving a workspace keeps its stale
   * row until the next non-empty payload or a `reset()`. A workspace
   * close/switch calls `reset()` (`handleWorkspaceEvent`), which is the case
   * that actually matters.
   */
  #install(rows: GitRepoStatus[]): boolean {
    if (rows.length === 0) return false;
    const sorted = [...rows].sort((a, b) => a.mountKey.localeCompare(b.mountKey));
    this.#rows = sorted;
    this.#reconcilePendingModes(sorted);
    // Fresh rows are the only honest answer to "is it still syncing?" — the
    // pass that produced them is over.
    for (const row of sorted) this.#stopSpin(row.mountKey);
    return true;
  }

  /** Retires an optimistic mode once the wire has moved off the value it replaced (or the mount is gone). */
  #reconcilePendingModes(rows: GitRepoStatus[]): void {
    const keys = Object.keys(this.#pendingModes);
    if (keys.length === 0) return;

    const next = { ...this.#pendingModes };
    let changed = false;
    for (const key of keys) {
      const row = rows.find((r) => r.mountKey === key);
      if (!row || row.mode !== next[key].replaced) {
        delete next[key];
        changed = true;
      }
    }
    if (changed) this.#pendingModes = next;
  }

  /**
   * "Sync now" — starts a pass and clears that repo's backoff (the one way
   * past a retry window). Answers as soon as the pass is STARTED; the result
   * arrives later as a `git_status` push.
   */
  async syncNow(mountKey: string, generation: number): Promise<string | null> {
    // Before the await, not after: the spin is feedback for the CLICK, and a
    // pass can finish (and clear it) while this call is still out.
    this.#startSpin(mountKey);
    const result = await this.#api.gitSyncNow(mountKey, generation);
    if (result.ok) return null;

    this.#stopSpin(mountKey);
    return gitErrorMessage(result.error);
  }

  #startSpin(mountKey: string): void {
    this.#clearTimer(mountKey);
    this.#syncing = { ...this.#syncing, [mountKey]: true };
    this.#syncTimers[mountKey] = setTimeout(
      () => this.#stopSpin(mountKey),
      SYNC_SPINNER_TIMEOUT_MS
    );
  }

  #stopSpin(mountKey: string): void {
    this.#clearTimer(mountKey);
    if (this.#syncing[mountKey] !== true) return;

    const next = { ...this.#syncing };
    delete next[mountKey];
    this.#syncing = next;
  }

  #clearTimer(mountKey: string): void {
    const timer = this.#syncTimers[mountKey];
    if (timer === undefined) return;
    clearTimeout(timer);
    delete this.#syncTimers[mountKey];
  }

  /**
   * Writes the ICM's `sync:` mode (`full` | `pull` | `off`).
   *
   * Deliberately does NOT re-read afterwards: `git_status` answers from the
   * last completed pass's cache, which still holds the OLD mode, so a re-read
   * here would make the picker snap back to the previous option. The saved
   * choice is shown immediately as an optimistic overlay (`#pendingModes`)
   * and retired by the push from the pass `{:mounts_changed}` triggers.
   */
  async setMode(mountKey: string, mode: string, generation: number): Promise<string | null> {
    // The WIRE's mode, not `byMountKey`'s overlaid one: after a second click
    // the overlay already reads as the user's previous choice, and recording
    // that as `replaced` would retire the new overlay on the very next stale
    // push.
    const replaced = this.#rows.find((row) => row.mountKey === mountKey)?.mode ?? '';
    const result = await this.#api.setIcmGitSync(mountKey, mode, generation);
    if (!result.ok) return gitErrorMessage(result.error);
    this.#pendingModes = { ...this.#pendingModes, [mountKey]: { mode, replaced } };
    return null;
  }

  /**
   * The ".valea/ → .gitignore" offer's consent action: writes the line (and
   * untracks the folder if git already had it), then re-reads the rows so the
   * card retires without waiting for the next push. Answers `null` on
   * success, a rendered message otherwise.
   *
   * Here rather than in the card because every other git RPC is here — one
   * place that knows how a git failure is worded, and one place a test can
   * reach without a component harness.
   */
  async addValeaGitignore(mountKey: string, generation: number): Promise<string | null> {
    const result = await this.#api.addValeaGitignore(mountKey, generation);
    if (!result.ok) return gitErrorMessage(result.error);

    await this.refresh(generation);
    return null;
  }

  /**
   * "Not now" — durable, per mount. No refresh: the dismissal lives on the
   * mount's config entry, and the backend's `{:mounts_changed}` broadcast is
   * what brings the mounts store (which the card reads) back in step.
   */
  async dismissGitOffer(
    mountKey: string,
    offerId: string,
    generation: number
  ): Promise<string | null> {
    const result = await this.#api.dismissGitOffer(mountKey, offerId, generation);
    return result.ok ? null : gitErrorMessage(result.error);
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
