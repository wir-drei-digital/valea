import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  GitStore,
  GIT_ATTENTION_STATES,
  gitAttentionText,
  gitErrorMessage,
  gitStateLabel,
  gitStatusLine,
  normalizeGitRepoRows,
  normalizeGitRepoStatus,
  SYNC_SPINNER_TIMEOUT_MS
} from './git.svelte';
import { workspaceStore } from './workspace.svelte';

beforeEach(() => {
  workspaceStore.generation = 7;
});

type Call = { fn: string; args: unknown[] };

/** Records every call in order and returns canned ApiResults — the `Pick<Api>` fake convention (`calendar.test.ts`). */
function fakeApi(overrides: Record<string, unknown> = {}) {
  const calls: Call[] = [];
  const ok = (data: unknown) => async () => ({ ok: true as const, data });
  const record =
    (fn: string, impl: (...args: unknown[]) => Promise<unknown>) =>
    async (...args: unknown[]) => {
      calls.push({ fn, args });
      return impl(...args);
    };

  const base: Record<string, (...args: unknown[]) => Promise<unknown>> = {
    gitStatus: ok({ repos: [] }),
    gitSyncNow: ok({ started: true }),
    setIcmGitSync: ok({ saved: true }),
    startGitConflictSession: ok({ sessionId: 'sess-1', routed: 'new' }),
    addValeaGitignore: ok({ saved: true, untracked: false }),
    dismissGitOffer: ok({ saved: true }),
    ...(overrides as Record<string, (...args: unknown[]) => Promise<unknown>>)
  };

  const wrapped = Object.fromEntries(Object.entries(base).map(([fn, impl]) => [fn, record(fn, impl)]));
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return { api: wrapped as any, calls };
}

/** One `Valea.Git.Engine.public_rows/1` row, exactly as the wire spells it (snake_case, string keys). */
function repoRow(partial: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    mount_key: 'workspace',
    icm_name: 'workspace',
    mode: 'full',
    state: 'ok',
    reason: null,
    branch: 'main',
    ahead: 0,
    behind: 0,
    dirty: false,
    local_sha: 'aaa111',
    remote_sha: 'aaa111',
    last_sync_at: '2026-07-30T08:00:00Z',
    last_error: null,
    conflict_session_id: null,
    valea_ignored: true,
    valea_tracked: false,
    ...partial
  };
}

describe('normalizeGitRepoStatus', () => {
  it('camelCases the snake_case wire row the backend actually sends', () => {
    const row = normalizeGitRepoStatus(
      repoRow({ state: 'diverged', ahead: 1, behind: 2, dirty: true, conflict_session_id: 'sess-9' })
    );

    expect(row).toEqual({
      mountKey: 'workspace',
      icmName: 'workspace',
      mode: 'full',
      state: 'diverged',
      reason: null,
      branch: 'main',
      ahead: 1,
      behind: 2,
      dirty: true,
      localSha: 'aaa111',
      remoteSha: 'aaa111',
      lastSyncAt: '2026-07-30T08:00:00Z',
      lastError: null,
      conflictSessionId: 'sess-9',
      valeaIgnored: true,
      valeaTracked: false
    });
  });

  // Tri-state on purpose: the backend sends `null` for a row it did not ask
  // (an `off`-mode ICM, a non-repo), and only a real `false` earns the
  // ".valea/ → .gitignore" offer.
  it('keeps the .valea facts tri-state — a missing one is null, never false', () => {
    expect(normalizeGitRepoStatus(repoRow({ valea_ignored: false, valea_tracked: true }))).toMatchObject({
      valeaIgnored: false,
      valeaTracked: true
    });

    const unasked = normalizeGitRepoStatus(
      repoRow({ valea_ignored: undefined, valea_tracked: undefined })
    );
    expect(unasked).toMatchObject({ valeaIgnored: null, valeaTracked: null });

    // Camel spelling is tolerated here too (the `pick()` dual-read stance).
    expect(
      normalizeGitRepoStatus({ ...repoRow({ valea_ignored: undefined }), valeaIgnored: false })
    ).toMatchObject({ valeaIgnored: false });
  });

  it('tolerates a camelCased row (the `pick()` dual-read stance of today/cockpit.ts)', () => {
    const row = normalizeGitRepoStatus({
      mountKey: 'life',
      icmName: 'life',
      mode: 'pull',
      state: 'blocked_local',
      reason: 'local edits',
      branch: 'main',
      ahead: 0,
      behind: 3,
      dirty: true,
      localSha: 'bbb222',
      remoteSha: 'ccc333',
      lastSyncAt: '2026-07-30T09:00:00Z',
      lastError: null,
      conflictSessionId: null
    });

    expect(row).toMatchObject({
      mountKey: 'life',
      icmName: 'life',
      state: 'blocked_local',
      behind: 3,
      lastSyncAt: '2026-07-30T09:00:00Z'
    });
  });

  it('drops a row that could not be identified or classified', () => {
    expect(normalizeGitRepoStatus(repoRow({ mount_key: null }))).toBeNull();
    expect(normalizeGitRepoStatus(repoRow({ state: null }))).toBeNull();
    expect(normalizeGitRepoStatus(null)).toBeNull();
    expect(normalizeGitRepoStatus('workspace')).toBeNull();
    expect(normalizeGitRepoStatus([repoRow()])).toBeNull();
  });

  it('degrades non-numeric counters to 0 rather than propagating NaN', () => {
    const row = normalizeGitRepoStatus(repoRow({ ahead: null, behind: 'two' }));
    expect(row).toMatchObject({ ahead: 0, behind: 0 });
  });

  it('normalizeGitRepoRows keeps only the rows that survive, sorted by mount key', () => {
    const rows = normalizeGitRepoRows([
      repoRow({ mount_key: 'life' }),
      'junk',
      repoRow({ mount_key: 'archive', state: null }),
      repoRow({ mount_key: 'workspace' })
    ]);

    expect(rows.map((r) => r.mountKey)).toEqual(['life', 'workspace']);
    expect(normalizeGitRepoRows(undefined)).toEqual([]);
  });
});

describe('gitAttentionText', () => {
  it('names the ICM and the counts for a diverged repo', () => {
    const repo = normalizeGitRepoStatus(repoRow({ state: 'diverged', ahead: 1, behind: 2 }))!;
    expect(gitAttentionText(repo)).toBe('workspace: local and remote diverged (1 ahead / 2 behind)');
  });

  it('reads plainly for the two other agent-actionable states', () => {
    const blocked = normalizeGitRepoStatus(repoRow({ state: 'blocked_local' }))!;
    const merging = normalizeGitRepoStatus(repoRow({ state: 'merge_in_progress' }))!;

    expect(gitAttentionText(blocked)).toBe('workspace: local edits block sync');
    expect(gitAttentionText(merging)).toBe('workspace: unfinished merge in the working tree');
  });

  it('falls back to the row’s own reason (then its state) for anything else', () => {
    const unsupported = normalizeGitRepoStatus(
      repoRow({ state: 'unsupported', reason: 'no git repository' })
    )!;
    const detached = normalizeGitRepoStatus(repoRow({ state: 'detached', icm_name: '' }))!;

    expect(gitAttentionText(unsupported)).toBe('workspace: no git repository');
    // No name and no reason: the mount key stands in, and the state is the sentence.
    expect(gitAttentionText(detached)).toBe('workspace: detached');
  });
});

describe('gitStateLabel', () => {
  it('gives every wire state a human word and passes an unknown one through', () => {
    expect(gitStateLabel('ok')).toBe('In sync');
    expect(gitStateLabel('merge_in_progress')).toBe('Merge in progress');
    expect(gitStateLabel('no_upstream')).toBe('No upstream branch');
    expect(gitStateLabel('something_new')).toBe('something_new');
  });
});

describe('gitErrorMessage', () => {
  it('translates the SHARED machine codes and passes git prose through untouched', () => {
    expect(gitErrorMessage('workspace_not_open')).toBe('No workspace is open.');
    expect(gitErrorMessage('workspace_changed')).toBe('Your workspace changed. Reopen it and try again.');
    expect(gitErrorMessage('icm_unavailable')).toBe("That ICM isn't available right now.");
    // Git-specific errors carry a human sentence in `type` — never re-worded here.
    expect(gitErrorMessage('No git conflict to resolve — it may have just cleared.')).toBe(
      'No git conflict to resolve — it may have just cleared.'
    );
  });
});

describe('GitStore.refresh', () => {
  it('sends the generation it was given and applies the rows', async () => {
    const { api, calls } = fakeApi({
      gitStatus: async () => ({ ok: true, data: { repos: [repoRow({ mount_key: 'life' }), repoRow()] } })
    });
    const store = new GitStore(api);

    await store.refresh(3);

    expect(calls).toEqual([{ fn: 'gitStatus', args: [3] }]);
    expect(store.repos.map((r) => r.mountKey)).toEqual(['life', 'workspace']);
  });

  it('falls back to the workspace store’s generation', async () => {
    const { api, calls } = fakeApi();
    await new GitStore(api).refresh();
    expect(calls[0].args).toEqual([7]);
  });

  it('keeps the last good rows when the RPC fails', async () => {
    const { api } = fakeApi({ gitStatus: async () => ({ ok: false, error: 'workspace_changed' }) });
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow()] });

    await store.refresh(3);

    expect(store.repos.map((r) => r.mountKey)).toEqual(['workspace']);
  });

  it('keeps the previous rows when the RPC answers empty (busy engine)', async () => {
    const { api } = fakeApi();
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow()] });

    await store.refresh(3);

    expect(store.repos.map((r) => r.mountKey)).toEqual(['workspace']);
  });
});

// The three feeds are async and unordered. A read answers from
// `Engine.statuses()` — the LAST COMPLETED pass's cached map — so a reply that
// lands after a push is, by construction, the older truth: re-installing it
// would resurrect a conflict the newest pass had already cleared (Today row +
// sidebar dot back until the next poll).
describe('GitStore ordering', () => {
  it('a read that started before a push cannot overwrite it', async () => {
    let release: (value: unknown) => void = () => {};
    const pending = new Promise((resolve) => (release = resolve));
    const { api } = fakeApi({
      gitStatus: async () => {
        await pending;
        // The stale snapshot: still diverged.
        return { ok: true, data: { repos: [repoRow({ state: 'diverged', ahead: 1, behind: 2 })] } };
      }
    });
    const store = new GitStore(api);

    const inFlight = store.refresh(3);
    // The pass finishes and pushes the resolved state while the read is out.
    store.handleGitStatus({ repos: [repoRow({ state: 'ok' })] });
    release(null);
    await inFlight;

    expect(store.byMountKey('workspace')?.state).toBe('ok');
  });

  it('an EMPTY push does not supersede a read in flight — it said nothing', async () => {
    let release: (value: unknown) => void = () => {};
    const pending = new Promise((resolve) => (release = resolve));
    const { api } = fakeApi({
      gitStatus: async () => {
        await pending;
        return { ok: true, data: { repos: [repoRow({ state: 'diverged' })] } };
      }
    });
    const store = new GitStore(api);

    const inFlight = store.refresh(3);
    store.handleGitStatus({ repos: [] });
    release(null);
    await inFlight;

    expect(store.byMountKey('workspace')?.state).toBe('diverged');
  });

  it('only the most recently STARTED read may install (CalendarStore.#fetchToken pattern)', async () => {
    let releaseSlow: (value: unknown) => void = () => {};
    const slow = new Promise((resolve) => (releaseSlow = resolve));
    let call = 0;
    const { api } = fakeApi({
      gitStatus: async () => {
        call += 1;
        if (call === 1) {
          await slow;
          return { ok: true, data: { repos: [repoRow({ branch: 'stale' })] } };
        }
        return { ok: true, data: { repos: [repoRow({ branch: 'fresh' })] } };
      }
    });
    const store = new GitStore(api);

    const first = store.refresh(3);
    await store.refresh(3);
    releaseSlow(null);
    await first;

    expect(store.byMountKey('workspace')?.branch).toBe('fresh');
  });

  it('a read still in flight when the workspace resets cannot land after it', async () => {
    let release: (value: unknown) => void = () => {};
    const pending = new Promise((resolve) => (release = resolve));
    const { api } = fakeApi({
      gitStatus: async () => {
        await pending;
        return { ok: true, data: { repos: [repoRow()] } };
      }
    });
    const store = new GitStore(api);

    const inFlight = store.refresh(3);
    store.reset();
    release(null);
    await inFlight;

    expect(store.repos).toEqual([]);
  });
});

describe('GitStore.handleGitStatus', () => {
  it('replaces the rows from a push, sorted by mount key, junk dropped', () => {
    const store = new GitStore(fakeApi().api);

    store.handleGitStatus({
      repos: [repoRow({ mount_key: 'workspace' }), repoRow({ mount_key: 'life' }), { nope: true }]
    });

    expect(store.repos.map((r) => r.mountKey)).toEqual(['life', 'workspace']);
  });

  // Ledgered busy-engine caveat: a busy engine briefly answers with NO rows
  // (on the push, the RPC and the cockpit block alike). An empty payload is
  // never a terminal empty state.
  it('keeps the previous rows when a payload arrives empty (busy engine)', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow()] });

    store.handleGitStatus({ repos: [] });

    expect(store.repos.map((r) => r.mountKey)).toEqual(['workspace']);
  });

  it('survives a malformed push', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow()] });

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    store.handleGitStatus({ repos: 'nope' } as any);

    expect(store.repos).toHaveLength(1);
  });
});

describe('GitStore.byMountKey / attention', () => {
  it('finds a row by mount key and answers null for an unknown one', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow()] });

    expect(store.byMountKey('workspace')?.branch).toBe('main');
    expect(store.byMountKey('nothing-here')).toBeNull();
  });

  it('flags attention for EXACTLY the three agent-actionable states', () => {
    const store = new GitStore(fakeApi().api);
    const states = [
      'ok',
      'syncing',
      'diverged',
      'blocked_local',
      'merge_in_progress',
      'error',
      'off',
      'detached',
      'no_upstream',
      'unsupported'
    ];
    store.handleGitStatus({ repos: states.map((state, i) => repoRow({ mount_key: `m${i}`, state })) });

    const flagged = states.filter((_, i) => store.attention(`m${i}`));
    expect(flagged).toEqual(['diverged', 'blocked_local', 'merge_in_progress']);
    expect([...GIT_ATTENTION_STATES]).toEqual(['diverged', 'blocked_local', 'merge_in_progress']);
    // An unknown mount is never in attention.
    expect(store.attention('not-a-mount')).toBe(false);
  });

  it('exposes the attention rows in mount-key order', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({
      repos: [
        repoRow({ mount_key: 'workspace', state: 'diverged' }),
        repoRow({ mount_key: 'archive', state: 'ok' }),
        repoRow({ mount_key: 'life', state: 'merge_in_progress' })
      ]
    });

    expect(store.attentionRepos.map((r) => r.mountKey)).toEqual(['life', 'workspace']);
  });
});

describe('gitStatusLine', () => {
  it('reads as one line, with the state leading only when it is worth saying', () => {
    const ok = normalizeGitRepoStatus(repoRow({ ahead: 1, behind: 2, dirty: true }))!;
    expect(gitStatusLine(ok)).toBe('main · 1 ahead / 2 behind · uncommitted changes');

    const level = normalizeGitRepoStatus(repoRow())!;
    expect(gitStatusLine(level)).toBe('main');

    const held = normalizeGitRepoStatus(repoRow({ state: 'diverged', ahead: 1, behind: 2 }))!;
    expect(gitStatusLine(held)).toBe('Diverged · main · 1 ahead / 2 behind');

    // Nothing git could answer — an empty line, not a string of separators.
    const blank = normalizeGitRepoStatus(repoRow({ state: 'ok', branch: null }))!;
    expect(gitStatusLine(blank)).toBe('');
  });
});

describe('GitStore.gitRowSignal', () => {
  function signalFor(partial: Record<string, unknown>) {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow(partial)] });
    return store.gitRowSignal('workspace');
  }

  it('says nothing at all for a mount with no row', () => {
    const store = new GitStore(fakeApi().api);
    expect(store.gitRowSignal('nothing-here')).toEqual({
      present: false,
      visible: false,
      ahead: 0,
      behind: 0,
      dirty: false,
      attention: false,
      spinning: false
    });
  });

  it('is present but invisible for a level, clean, unheld repo', () => {
    expect(signalFor({})).toMatchObject({ present: true, visible: false, attention: false });
  });

  it('becomes visible for ahead, behind, dirty — separately and together', () => {
    expect(signalFor({ ahead: 1 })).toMatchObject({ visible: true, ahead: 1, behind: 0 });
    expect(signalFor({ behind: 3 })).toMatchObject({ visible: true, ahead: 0, behind: 3 });
    expect(signalFor({ dirty: true })).toMatchObject({ visible: true, dirty: true });
    expect(signalFor({ ahead: 2, behind: 3, dirty: true })).toMatchObject({
      visible: true,
      ahead: 2,
      behind: 3,
      dirty: true
    });
  });

  it('flags attention for exactly the three agent-actionable holds', () => {
    const states = [
      'ok',
      'syncing',
      'diverged',
      'blocked_local',
      'merge_in_progress',
      'error',
      'off',
      'detached',
      'no_upstream',
      'unsupported'
    ];
    const attention = states.filter((state) => signalFor({ state }).attention);

    expect(attention).toEqual(['diverged', 'blocked_local', 'merge_in_progress']);
    // A hold is always visible, even with nothing ahead, behind or dirty.
    expect(signalFor({ state: 'diverged' })).toMatchObject({ visible: true, attention: true });
    // And a non-hold that is otherwise quiet stays quiet.
    expect(signalFor({ state: 'error' })).toMatchObject({ visible: false, attention: false });
  });
});

describe('GitStore.syncNow — the click spinner', () => {
  it('spins on the click and stops when a pass installs rows', async () => {
    const { api } = fakeApi();
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow()] });

    const inFlight = store.syncNow('workspace', 7);
    expect(store.gitRowSignal('workspace').spinning).toBe(true);
    await inFlight;
    expect(store.gitRowSignal('workspace').spinning).toBe(true);

    store.handleGitStatus({ repos: [repoRow({ ahead: 1 })] });

    expect(store.gitRowSignal('workspace').spinning).toBe(false);
  });

  it('an EMPTY payload installs nothing, so it does not stop the spinner', async () => {
    const { api } = fakeApi();
    const store = new GitStore(api);
    await store.syncNow('workspace', 7);

    store.handleGitStatus({ repos: [] });

    expect(store.gitRowSignal('workspace').spinning).toBe(true);
  });

  it('stops on a failed request — nothing was started', async () => {
    const { api } = fakeApi({ gitSyncNow: async () => ({ ok: false, error: 'workspace_not_open' }) });
    const store = new GitStore(api);

    expect(await store.syncNow('workspace', 7)).toBe('No workspace is open.');
    expect(store.gitRowSignal('workspace').spinning).toBe(false);
  });

  // The engine never emits a `syncing` state, so nothing on the wire is
  // guaranteed to arrive — the timeout is what stops an icon spinning forever
  // when a workspace closes under the click.
  it('gives up after the timeout', async () => {
    vi.useFakeTimers();
    try {
      const { api } = fakeApi();
      const store = new GitStore(api);
      await store.syncNow('workspace', 7);
      expect(store.gitRowSignal('workspace').spinning).toBe(true);

      vi.advanceTimersByTime(SYNC_SPINNER_TIMEOUT_MS + 1);

      expect(store.gitRowSignal('workspace').spinning).toBe(false);
    } finally {
      vi.useRealTimers();
    }
  });

  it('a reset drops the spinner with everything else', async () => {
    const { api } = fakeApi();
    const store = new GitStore(api);
    await store.syncNow('workspace', 7);

    store.reset();

    expect(store.gitRowSignal('workspace').spinning).toBe(false);
  });
});

describe('GitStore actions', () => {
  it('syncNow answers null on success and a rendered message on failure', async () => {
    const { api, calls } = fakeApi();
    expect(await new GitStore(api).syncNow('workspace', 7)).toBeNull();
    expect(calls).toEqual([{ fn: 'gitSyncNow', args: ['workspace', 7] }]);

    const failing = fakeApi({
      gitSyncNow: async () => ({ ok: false, error: 'Git engine is not running — is a workspace open?' })
    });
    expect(await new GitStore(failing.api).syncNow('workspace', 7)).toBe(
      'Git engine is not running — is a workspace open?'
    );
  });

  it('setMode passes the mode through and does NOT re-read (the cache still holds the old mode)', async () => {
    const { api, calls } = fakeApi();
    const store = new GitStore(api);

    expect(await store.setMode('workspace', 'pull', 7)).toBeNull();

    expect(calls.map((c) => c.fn)).toEqual(['setIcmGitSync']);
    expect(calls[0].args).toEqual(['workspace', 'pull', 7]);
  });

  it('setMode renders a shared machine code as a sentence and does NOT refresh', async () => {
    const { api, calls } = fakeApi({
      setIcmGitSync: async () => ({ ok: false, error: 'workspace_not_open' })
    });

    expect(await new GitStore(api).setMode('workspace', 'off', 7)).toBe('No workspace is open.');
    expect(calls.map((c) => c.fn)).toEqual(['setIcmGitSync']);
  });

  it('startConflictSession returns the routed session, or the message', async () => {
    const { api, calls } = fakeApi({
      startGitConflictSession: async () => ({ ok: true, data: { sessionId: 'sess-42', routed: 'existing' } })
    });

    expect(await new GitStore(api).startConflictSession('workspace', 7)).toEqual({
      ok: true,
      sessionId: 'sess-42',
      routed: 'existing'
    });
    expect(calls).toEqual([{ fn: 'startGitConflictSession', args: ['workspace', 7] }]);

    const failing = fakeApi({
      startGitConflictSession: async () => ({
        ok: false,
        error: 'No git conflict to resolve — it may have just cleared.'
      })
    });
    expect(await new GitStore(failing.api).startConflictSession('workspace', 7)).toEqual({
      ok: false,
      error: 'No git conflict to resolve — it may have just cleared.'
    });
  });

  // The conflict just cleared under the user: the message is shown inline AND
  // the rows are refreshed, so the stale attention row disappears on its own.
  it('startConflictSession refreshes the rows after a failure', async () => {
    const { api, calls } = fakeApi({
      startGitConflictSession: async () => ({ ok: false, error: 'No git conflict to resolve — it may have just cleared.' })
    });

    await new GitStore(api).startConflictSession('workspace', 7);

    expect(calls.map((c) => c.fn)).toEqual(['startGitConflictSession', 'gitStatus']);
  });
});

// `set_icm_git_sync` writes the ICM's config and broadcasts
// `{:mounts_changed}` — it does NOT touch `Engine.statuses()`, and a row's
// `mode` is re-derived only inside a pass. So the saved choice is shown
// optimistically until a wire row catches up, or the picker visibly snaps back
// to the old option for as long as a pass (network fetch included) takes.
describe('GitStore.setMode — the optimistic mode overlay', () => {
  async function storeWithMode(mode: string) {
    const { api, calls } = fakeApi();
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow({ mode })] });
    return { store, calls };
  }

  it('shows the saved mode immediately', async () => {
    const { store } = await storeWithMode('off');

    await store.setMode('workspace', 'full', 7);

    expect(store.byMountKey('workspace')?.mode).toBe('full');
  });

  it('a later push still carrying the OLD mode does not clobber it', async () => {
    const { store } = await storeWithMode('off');
    await store.setMode('workspace', 'full', 7);

    // The pass that pushed this one started before the config write landed.
    store.handleGitStatus({ repos: [repoRow({ mode: 'off', state: 'diverged' })] });

    expect(store.byMountKey('workspace')?.mode).toBe('full');
    // Everything else on the row is the wire's, not frozen.
    expect(store.byMountKey('workspace')?.state).toBe('diverged');
  });

  it('a push carrying the NEW mode clears the overlay cleanly', async () => {
    const { store } = await storeWithMode('off');
    await store.setMode('workspace', 'full', 7);

    store.handleGitStatus({ repos: [repoRow({ mode: 'full' })] });
    // With the overlay retired, the wire is authoritative again — including a
    // later change made outside this UI.
    store.handleGitStatus({ repos: [repoRow({ mode: 'pull' })] });

    expect(store.byMountKey('workspace')?.mode).toBe('pull');
  });

  it('self-heals when the wire moves to some THIRD mode (edited underneath us)', async () => {
    const { store } = await storeWithMode('off');
    await store.setMode('workspace', 'full', 7);

    store.handleGitStatus({ repos: [repoRow({ mode: 'pull' })] });

    expect(store.byMountKey('workspace')?.mode).toBe('pull');
  });

  it('records the WIRE mode as the value being replaced, so a second click survives a stale push', async () => {
    const { store } = await storeWithMode('off');
    await store.setMode('workspace', 'full', 7);
    await store.setMode('workspace', 'pull', 7);

    store.handleGitStatus({ repos: [repoRow({ mode: 'off' })] });

    expect(store.byMountKey('workspace')?.mode).toBe('pull');
  });

  it('a failed save leaves no overlay behind', async () => {
    const { api } = fakeApi({ setIcmGitSync: async () => ({ ok: false, error: 'workspace_not_open' }) });
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow({ mode: 'off' })] });

    await store.setMode('workspace', 'full', 7);

    expect(store.byMountKey('workspace')?.mode).toBe('off');
  });
});

// The ".valea/ → .gitignore" card's two buttons. Both are consent actions —
// the write is the only place Valea edits a user's repository, and the
// dismissal is durable — so both are asserted down to their arguments.
describe('GitStore — the .valea gitignore offer', () => {
  it('writes the line and re-reads the rows, so the card retires', async () => {
    const { api, calls } = fakeApi();
    const store = new GitStore(api);

    expect(await store.addValeaGitignore('workspace', 7)).toBeNull();

    expect(calls.map((c) => c.fn)).toEqual(['addValeaGitignore', 'gitStatus']);
    expect(calls[0].args).toEqual(['workspace', 7]);
    expect(calls[1].args).toEqual([7]);
  });

  it('renders a failure and does NOT re-read — nothing changed', async () => {
    const { api, calls } = fakeApi({
      addValeaGitignore: async () => ({ ok: false, error: 'This ICM is not a git repository.' })
    });

    expect(await new GitStore(api).addValeaGitignore('workspace', 7)).toBe(
      'This ICM is not a git repository.'
    );
    expect(calls.map((c) => c.fn)).toEqual(['addValeaGitignore']);
  });

  it('dismisses by offer id, with no refresh of its own', async () => {
    const { api, calls } = fakeApi();

    expect(await new GitStore(api).dismissGitOffer('workspace', 'valea_gitignore', 7)).toBeNull();
    expect(calls).toEqual([{ fn: 'dismissGitOffer', args: ['workspace', 'valea_gitignore', 7] }]);
  });

  it('renders a dismissal failure through the shared vocabulary', async () => {
    const { api } = fakeApi({
      dismissGitOffer: async () => ({ ok: false, error: 'workspace_changed' })
    });

    expect(await new GitStore(api).dismissGitOffer('workspace', 'valea_gitignore', 7)).toBe(
      'Your workspace changed. Reopen it and try again.'
    );
  });
});

describe('GitStore.reset', () => {
  it('drops every row — the workspace it described is gone', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow()] });

    store.reset();

    expect(store.repos).toEqual([]);
  });

  it('drops a pending mode too — it described the outgoing workspace', async () => {
    const { api } = fakeApi();
    const store = new GitStore(api);
    store.handleGitStatus({ repos: [repoRow({ mode: 'off' })] });
    await store.setMode('workspace', 'full', 7);

    store.reset();
    store.handleGitStatus({ repos: [repoRow({ mode: 'off' })] });

    expect(store.byMountKey('workspace')?.mode).toBe('off');
  });
});

describe('wireGitEvents', () => {
  it('binds git_status once, however often it is called', async () => {
    const { wireGitEvents } = await import('./git.svelte');
    const bound: string[] = [];
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const channel = { on: (event: string) => bound.push(event) } as any;

    wireGitEvents(channel);
    wireGitEvents(channel);

    expect(bound).toEqual(['git_status']);
  });
});

describe('resolveGitConflict', () => {
  it('routes straight to a recorded session without an RPC', async () => {
    const { resolveGitConflict, gitStore } = await import('./git.svelte');
    const repo = normalizeGitRepoStatus(repoRow({ state: 'diverged', conflict_session_id: 'sess-live' }))!;
    const start = vi.spyOn(gitStore, 'startConflictSession');

    expect(await resolveGitConflict(repo, 7)).toEqual({ ok: true, sessionId: 'sess-live' });
    expect(start).not.toHaveBeenCalled();

    start.mockRestore();
  });

  it('starts one otherwise, and refreshes the sidebar’s session list first', async () => {
    const { resolveGitConflict, gitStore } = await import('./git.svelte');
    const { recentSessionsStore } = await import('./recent-sessions.svelte');
    const repo = normalizeGitRepoStatus(repoRow({ state: 'diverged' }))!;

    const start = vi
      .spyOn(gitStore, 'startConflictSession')
      .mockResolvedValue({ ok: true, sessionId: 'sess-new', routed: 'new' });
    const recent = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    expect(await resolveGitConflict(repo, 7)).toEqual({ ok: true, sessionId: 'sess-new' });
    expect(start).toHaveBeenCalledWith('workspace', 7);
    expect(recent).toHaveBeenCalledTimes(1);

    start.mockRestore();
    recent.mockRestore();
  });

  it('passes a failure back for the caller to render inline', async () => {
    const { resolveGitConflict, gitStore } = await import('./git.svelte');
    const repo = normalizeGitRepoStatus(repoRow({ state: 'diverged' }))!;
    const start = vi
      .spyOn(gitStore, 'startConflictSession')
      .mockResolvedValue({ ok: false, error: 'No git conflict to resolve — it may have just cleared.' });

    expect(await resolveGitConflict(repo, 7)).toEqual({
      ok: false,
      error: 'No git conflict to resolve — it may have just cleared.'
    });

    start.mockRestore();
  });
});
