import { beforeEach, describe, expect, it, vi } from 'vitest';
import {
  GitStore,
  GIT_ATTENTION_STATES,
  gitAttentionText,
  gitErrorMessage,
  gitStateLabel,
  normalizeGitRepoRows,
  normalizeGitRepoStatus
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
      conflictSessionId: 'sess-9'
    });
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
    const { api } = fakeApi({ gitStatus: async () => ({ ok: true, data: { repos: [repoRow()] } }) });
    const store = new GitStore(api);
    await store.refresh(3);

    const failing = fakeApi({ gitStatus: async () => ({ ok: false, error: 'workspace_changed' }) });
    const store2 = new GitStore(failing.api);
    store2.applyRows(store.repos);
    await store2.refresh(3);

    expect(store2.repos.map((r) => r.mountKey)).toEqual(['workspace']);
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

  it('setMode passes the mode through and refreshes the rows on success', async () => {
    const { api, calls } = fakeApi();
    const store = new GitStore(api);

    expect(await store.setMode('workspace', 'pull', 7)).toBeNull();

    expect(calls.map((c) => c.fn)).toEqual(['setIcmGitSync', 'gitStatus']);
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

describe('GitStore.reset', () => {
  it('drops every row — the workspace it described is gone', () => {
    const store = new GitStore(fakeApi().api);
    store.handleGitStatus({ repos: [repoRow()] });

    store.reset();

    expect(store.repos).toEqual([]);
  });
});

describe('GitStore.applyRows', () => {
  it('is the cockpit payload’s door into the store, with the SAME keep-on-empty policy', () => {
    const store = new GitStore(fakeApi().api);
    const rows = normalizeGitRepoRows([repoRow()]);

    store.applyRows(rows);
    expect(store.repos).toHaveLength(1);

    store.applyRows([]);
    expect(store.repos).toHaveLength(1);
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
