import { describe, it, expect, vi } from 'vitest';
import { normalizeIcmNode, IcmStore, refreshSidebarProjectStores, handleWorkspaceEvent, icmStore } from './icm.svelte';
import { mountsStore } from './mounts.svelte';
import { recentSessionsStore } from './recent-sessions.svelte';
import { workspaceStore } from './workspace.svelte';
import type { IcmNode } from '../shell/nav';
import type { ApiResult } from '../api/client';

describe('normalizeIcmNode', () => {
  it('normalizes snake_case page_count from the wire, stamping mountKey', () => {
    const raw = {
      name: 'My Folder',
      path: 'my-folder',
      type: 'folder',
      page_count: 3,
      children: []
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result).toEqual<IcmNode>({
      name: 'My Folder',
      path: 'my-folder',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 3,
      children: []
    });
  });

  it('normalizes camelCase pageCount for backward compatibility', () => {
    const raw = {
      name: 'My Folder',
      path: 'my-folder',
      type: 'folder',
      pageCount: 5,
      children: []
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result).toEqual<IcmNode>({
      name: 'My Folder',
      path: 'my-folder',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 5,
      children: []
    });
  });

  it('defaults pageCount to 0 when missing', () => {
    const raw = {
      name: 'Empty Folder',
      path: 'empty',
      type: 'folder',
      children: []
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result).toEqual<IcmNode>({
      name: 'Empty Folder',
      path: 'empty',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 0,
      children: []
    });
  });

  it('normalizes nested children with snake_case counts, stamping the same mountKey throughout', () => {
    const raw = {
      name: 'Parent',
      path: 'parent',
      type: 'folder',
      page_count: 2,
      children: [
        {
          name: 'Child Folder',
          path: 'parent/child',
          type: 'folder',
          page_count: 1,
          children: []
        },
        {
          name: 'Page',
          path: 'parent/page',
          type: 'page',
          uri: 'page-uri-123'
        }
      ]
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result).toEqual<IcmNode>({
      name: 'Parent',
      path: 'parent',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 2,
      children: [
        {
          name: 'Child Folder',
          path: 'parent/child',
          mountKey: 'primary',
          type: 'folder',
          pageCount: 1,
          children: []
        },
        {
          name: 'Page',
          path: 'parent/page',
          mountKey: 'primary',
          type: 'page',
          uri: 'page-uri-123'
        }
      ]
    });
  });

  it('normalizes page nodes without pageCount', () => {
    const raw = {
      name: 'My Page',
      path: 'my-page',
      type: 'page',
      uri: 'page-uri-456'
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result).toEqual<IcmNode>({
      name: 'My Page',
      path: 'my-page',
      mountKey: 'primary',
      type: 'page',
      uri: 'page-uri-456'
    });
  });

  it('prefers snake_case over camelCase when both present', () => {
    const raw = {
      name: 'Folder',
      path: 'folder',
      type: 'folder',
      page_count: 10,
      pageCount: 5, // snake_case should win
      children: []
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result.pageCount).toBe(10);
  });

  it('preserves file leaves (A-T15 fix wave) — type "file" with the ext passed through', () => {
    const raw = { name: 'X.pdf', path: 'Offers/X.pdf', type: 'file', ext: '.pdf' };

    expect(normalizeIcmNode(raw, 'primary')).toEqual<IcmNode>({
      name: 'X.pdf',
      path: 'Offers/X.pdf',
      mountKey: 'primary',
      type: 'file',
      ext: '.pdf'
    });
  });

  it('normalizes file leaves nested inside folder children', () => {
    const raw = {
      name: 'Offers',
      path: 'Offers',
      type: 'folder',
      page_count: 1,
      children: [
        { name: 'Founder Coaching', path: 'Offers/Founder Coaching.md', type: 'page', uri: 'u' },
        { name: 'logo.png', path: 'Offers/logo.png', type: 'file', ext: '.png' }
      ]
    };

    const result = normalizeIcmNode(raw, 'primary');

    expect(result.children?.[1]).toEqual<IcmNode>({
      name: 'logo.png',
      path: 'Offers/logo.png',
      mountKey: 'primary',
      type: 'file',
      ext: '.png'
    });
  });

  it('still coerces an unknown type to page (defensive default, unchanged)', () => {
    const raw = { name: 'Mystery', path: 'mystery', type: 'something_else', uri: 'u' };

    expect(normalizeIcmNode(raw, 'primary').type).toBe('page');
  });

  it('stamps a different mountKey for a different call', () => {
    const raw = { name: 'X', path: 'X.md', type: 'page', uri: 'u' };
    expect(normalizeIcmNode(raw, 'clients').mountKey).toBe('clients');
  });
});

// `IcmStore.refetch` (task 4.2/4.3 re-key) now fans out: `list_icms`
// (Task 3.4) reports the mount catalog, then `icm_tree` — single-ICM per
// call (Task 4.2) — is fetched once per enabled, non-degraded mount and
// assembled into the same grouped `MountGroup[]` shape this store always
// exposed. `icms` rows only need `mountKey`/`enabled`/`degraded` for this
// fan-out; `tree` rows only need `mountKey`/`title`/`tree`.
function fakeApi(
  icms: Array<{ mountKey: string; enabled: boolean; degraded: string | null }>,
  trees: Record<string, { title: string; tree: any[] } | undefined>
) {
  return {
    listIcms: async () => ({ ok: true, data: { icms } }) as ApiResult<any>,
    icmTree: async (mountKey: string) => {
      const tree = trees[mountKey];
      if (!tree) return { ok: false, error: 'outside_workspace' } as ApiResult<any>;
      return { ok: true, data: { mountKey, ...tree } } as ApiResult<any>;
    }
  };
}

describe('IcmStore.loaded', () => {
  it('starts false before any refetch resolves', () => {
    const store = new IcmStore(fakeApi([], {}));

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });

  it('flips true after a successful refetch, alongside populated groups', async () => {
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore(
      fakeApi(
        [{ mountKey: 'primary', enabled: true, degraded: null }],
        { primary: { title: 'Primary', tree: [raw] } }
      )
    );

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);
  });

  it('stays false when the mount list fetch fails, so callers keep showing the loading state', async () => {
    const store = new IcmStore({
      listIcms: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>,
      icmTree: async () => ({ ok: true, data: { mountKey: 'primary', title: 'Primary', tree: [] } }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(false);
  });

  it('remains true on subsequent refetches (never reverts to a loading state)', async () => {
    let call = 0;
    const api = fakeApi([], {});
    const store = new IcmStore({
      listIcms: async () => {
        call += 1;
        return api.listIcms();
      },
      icmTree: api.icmTree
    });

    await store.refetch();
    expect(store.loaded).toBe(true);

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(call).toBe(2);
  });
});

describe('IcmStore.refetch (fan-out tree assembly)', () => {
  it('fetches one tree per ENABLED, non-degraded mount and assembles a MountGroup per one', async () => {
    const rawPrimary = { name: 'Folder A', path: 'folder-a', type: 'folder', page_count: 1, children: [] };
    const rawClients = { name: 'Folder B', path: 'folder-b', type: 'folder', pageCount: 2, children: [] };

    const store = new IcmStore(
      fakeApi(
        [
          { mountKey: 'primary', enabled: true, degraded: null },
          { mountKey: 'clients', enabled: true, degraded: null }
        ],
        {
          primary: { title: 'Primary', tree: [rawPrimary] },
          clients: { title: 'Clients', tree: [rawClients] }
        }
      )
    );

    await store.refetch();

    expect(store.groups).toEqual([
      {
        mount: 'primary',
        title: 'Primary',
        tree: [{ name: 'Folder A', path: 'folder-a', mountKey: 'primary', type: 'folder', pageCount: 1, children: [] }]
      },
      {
        mount: 'clients',
        title: 'Clients',
        tree: [{ name: 'Folder B', path: 'folder-b', mountKey: 'clients', type: 'folder', pageCount: 2, children: [] }]
      }
    ]);
  });

  it('excludes a disabled or degraded mount from the fan-out entirely', async () => {
    const raw = { name: 'Folder A', path: 'folder-a', type: 'folder', page_count: 0, children: [] };

    const store = new IcmStore(
      fakeApi(
        [
          { mountKey: 'primary', enabled: true, degraded: null },
          { mountKey: 'off', enabled: false, degraded: null },
          { mountKey: 'broken', enabled: true, degraded: 'icm.yaml is missing' }
        ],
        { primary: { title: 'Primary', tree: [raw] } }
      )
    );

    await store.refetch();

    expect(store.groups.map((g) => g.mount)).toEqual(['primary']);
  });

  it('defaults to an empty groups array when there are no enabled mounts', async () => {
    const store = new IcmStore(fakeApi([], {}));

    await store.refetch();

    expect(store.groups).toEqual([]);
    expect(store.loaded).toBe(true);
  });

  it('drops a mount whose individual icm_tree call fails, keeping the others', async () => {
    const raw = { name: 'Folder A', path: 'folder-a', type: 'folder', page_count: 0, children: [] };

    const store = new IcmStore(
      fakeApi(
        [
          { mountKey: 'primary', enabled: true, degraded: null },
          { mountKey: 'gone', enabled: true, degraded: null }
        ],
        { primary: { title: 'Primary', tree: [raw] } }
      )
    );

    await store.refetch();

    expect(store.groups.map((g) => g.mount)).toEqual(['primary']);
  });

  it('leaves groups untouched on a mount-list failure', async () => {
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore(
      fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], { primary: { title: 'Primary', tree: [raw] } })
    );
    await store.refetch();

    const failing = new IcmStore({
      listIcms: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>,
      icmTree: async () => ({ ok: true, data: { mountKey: 'primary', title: 'Primary', tree: [] } }) as ApiResult<any>
    });
    await failing.refetch();

    expect(failing.groups).toEqual([]);
  });
});

// Acceptance fix wave (Task 9.3/9.4 re-review Finding 2 — generation-coherent
// refresh): `refetch` now takes an optional explicit `generation`, used by
// `handleWorkspaceEvent` (the LIVE-SWITCH path, tested further below) to
// override the `workspaceStore.generation` fallback with the workspace-change
// push's OWN generation.
describe('IcmStore.refetch (generation argument)', () => {
  it('prefers an explicit generation argument over workspaceStore.generation', async () => {
    workspaceStore.generation = 1; // stale — the OUTGOING workspace's generation
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ApiResult<any>);
    const store = new IcmStore({ listIcms, icmTree: async () => ({ ok: true, data: {} }) as ApiResult<any> });

    await store.refetch(7); // the INCOMING workspace's generation, from the event payload

    expect(listIcms).toHaveBeenCalledWith(7);
    workspaceStore.generation = null;
  });

  it('falls back to workspaceStore.generation when called bare, unchanged for every other caller', async () => {
    workspaceStore.generation = 42;
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ApiResult<any>);
    const store = new IcmStore({ listIcms, icmTree: async () => ({ ok: true, data: {} }) as ApiResult<any> });

    await store.refetch();

    expect(listIcms).toHaveBeenCalledWith(42);
    workspaceStore.generation = null;
  });

  it('threads the explicit generation into icmTree calls too, not just listIcms', async () => {
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const icmTree = vi.fn(
      async (mountKey: string) => ({ ok: true, data: { mountKey, title: 'Legal', tree: [raw] } }) as ApiResult<any>
    );
    const store = new IcmStore({
      listIcms: async () =>
        ({ ok: true, data: { icms: [{ mountKey: 'legal', enabled: true, degraded: null }] } }) as ApiResult<any>,
      icmTree
    });

    await store.refetch(7);

    expect(icmTree).toHaveBeenCalledWith('legal', 7);
  });

  // Reproduces the actual bug end-to-end with a fake backend that guards
  // generation exactly like `Valea.Api.Icms`'s `check_generation/1` —
  // accepting only the CURRENT (incoming) generation and otherwise returning
  // `workspace_changed`, same as a live switch's stale-generation RPC would.
  it('reproduces the switch-refresh bug: stale workspaceStore.generation is rejected, the event-supplied generation is not', async () => {
    const CURRENT_GENERATION = 7;
    workspaceStore.generation = 1; // stale, from before the switch
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const api = {
      listIcms: vi.fn(async (generation: number) =>
        generation === CURRENT_GENERATION
          ? (({ ok: true, data: { icms: [{ mountKey: 'legal', enabled: true, degraded: null }] } }) as ApiResult<any>)
          : (({ ok: false, error: 'workspace_changed' }) as ApiResult<any>)
      ),
      icmTree: async () => ({ ok: true, data: { mountKey: 'legal', title: 'Legal', tree: [raw] } }) as ApiResult<any>
    };

    const buggyStore = new IcmStore(api);
    await buggyStore.refetch(); // bare — falls back to the stale workspaceStore.generation
    expect(buggyStore.loaded).toBe(false);
    expect(buggyStore.groups).toEqual([]);

    const fixedStore = new IcmStore(api);
    await fixedStore.refetch(CURRENT_GENERATION); // explicit — the event's own generation
    expect(fixedStore.loaded).toBe(true);
    expect(fixedStore.groups).toHaveLength(1);

    workspaceStore.generation = null;
  });
});

describe('IcmStore.reset', () => {
  it('empties groups and clears loaded', async () => {
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore(
      fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], { primary: { title: 'Primary', tree: [raw] } })
    );

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });

  it('is safe to call before any refetch has resolved', () => {
    const store = new IcmStore(fakeApi([], {}));

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });

  it('allows a subsequent refetch to repopulate the tree after reset', async () => {
    const raw = { name: 'Folder', path: 'folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore(
      fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], { primary: { title: 'Primary', tree: [raw] } })
    );

    await store.refetch();
    store.reset();
    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);
  });
});

// Cold-load fix wave (browser-verified): `WorkspaceEventsChannel.join/3`
// pushes NOTHING on join — the `workspace` push (and with it `wireIcmEvents`'s
// `onWorkspace` handler) only fires on live `workspace_opened`/
// `workspace_closed` PubSub broadcasts, never on initial page load. The
// sidebar's project stores therefore need a second, cold-load call site: the
// root layout calls this once its bootstrap `get_workspace` resolves open.
describe('refreshSidebarProjectStores', () => {
  it('refreshes mountsStore AND recentSessionsStore — the two stores IcmProjects derives the sidebar groups from', () => {
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    refreshSidebarProjectStores();

    expect(mountsRefresh).toHaveBeenCalledTimes(1);
    expect(recentRefresh).toHaveBeenCalledTimes(1);

    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
  });

  // Acceptance fix wave (Task 9.3/9.4 re-review Finding 2): forwards an
  // explicit generation to mountsStore.refresh ONLY — recentSessionsStore's
  // RPC takes no generation at all (see the function's own doc comment).
  it('forwards an explicit generation to mountsStore.refresh, not recentSessionsStore.refresh', () => {
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    refreshSidebarProjectStores(7);

    expect(mountsRefresh).toHaveBeenCalledWith(7);
    expect(recentRefresh).toHaveBeenCalledWith();

    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
  });
});

// Acceptance fix wave (Task 9.3/9.4 re-review Finding 2 — generation-coherent
// refresh): reproduced twice in the live acceptance run
// (docs/superpowers/acceptance/2026-07-13-icm-project-workspaces.md,
// Scenario 5 Finding 2) — immediately after a LIVE workspace switch, the
// sidebar's ICM groups and recent sessions rendered empty until a manual
// reload. Root cause: this handler's open branch used to read
// `workspaceStore.generation`, which is DETERMINISTICALLY stale at this
// exact call site (see `wireIcmEvents`'s "CARRY-FORWARD (acceptance fix
// wave...)" doc comment for the full mechanism) — every `list_icms`/`icm_tree`
// RPC got rejected with `workspace_changed` by the backend's
// `check_generation/1` guard, so `icmStore`/`mountsStore` stayed reset. These
// tests simulate the exact ordering: `workspaceStore.generation` still holds
// the OLD (outgoing) value when the push arrives with the NEW (incoming) one.
describe('handleWorkspaceEvent (LIVE SWITCH — generation-coherent refresh)', () => {
  it('resets all three sidebar stores unconditionally on a close push, without refetching/refreshing any of them', () => {
    const icmReset = vi.spyOn(icmStore, 'reset');
    const mountsReset = vi.spyOn(mountsStore, 'reset');
    const recentReset = vi.spyOn(recentSessionsStore, 'reset');
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    handleWorkspaceEvent({ open: false });

    expect(icmReset).toHaveBeenCalledTimes(1);
    expect(mountsReset).toHaveBeenCalledTimes(1);
    expect(recentReset).toHaveBeenCalledTimes(1);
    expect(icmRefetch).not.toHaveBeenCalled();
    expect(mountsRefresh).not.toHaveBeenCalled();
    expect(recentRefresh).not.toHaveBeenCalled();

    icmReset.mockRestore();
    mountsReset.mockRestore();
    recentReset.mockRestore();
    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
  });

  it("on an open push, threads the PUSH'S OWN generation into icmStore.refetch and mountsStore.refresh — not workspaceStore's stale one", () => {
    workspaceStore.generation = 1; // stale — the OUTGOING workspace's generation; workspaceStore.refresh() hasn't resolved yet
    const icmReset = vi.spyOn(icmStore, 'reset');
    const mountsReset = vi.spyOn(mountsStore, 'reset');
    const recentReset = vi.spyOn(recentSessionsStore, 'reset');
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    handleWorkspaceEvent({ open: true, generation: 7, name: 'Consulting', path: '/ws/consulting' });

    expect(icmReset).toHaveBeenCalledTimes(1);
    expect(mountsReset).toHaveBeenCalledTimes(1);
    expect(recentReset).toHaveBeenCalledTimes(1);
    expect(icmRefetch).toHaveBeenCalledWith(7);
    expect(mountsRefresh).toHaveBeenCalledWith(7);
    expect(recentRefresh).toHaveBeenCalledTimes(1); // no generation argument — see refreshSidebarProjectStores' doc comment

    icmReset.mockRestore();
    mountsReset.mockRestore();
    recentReset.mockRestore();
    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
    workspaceStore.generation = null;
  });

  it('passes payload.generation through verbatim, even when absent — the workspaceStore.generation fallback lives one layer down, in IcmStore.refetch/MountsStore.refresh themselves (see their own tests)', () => {
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);

    // Defensive case only — the backend always sends `generation` on an
    // `open: true` push (`WorkspaceEventsChannel.handle_info/2`).
    handleWorkspaceEvent({ open: true });

    expect(icmRefetch).toHaveBeenCalledWith(undefined);
    expect(mountsRefresh).toHaveBeenCalledWith(undefined);

    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
  });
});
