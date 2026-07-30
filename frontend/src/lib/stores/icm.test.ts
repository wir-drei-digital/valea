import { describe, it, expect, vi } from 'vitest';
import { normalizeIcmNode, IcmStore, refreshSidebarProjectStores, handleWorkspaceEvent, icmStore } from './icm.svelte';
import { mountsStore } from './mounts.svelte';
import { recentSessionsStore } from './recent-sessions.svelte';
import { sessionsListStore } from './sessions-list.svelte';
import { workspaceStore } from './workspace.svelte';
import { tasksStore } from '../tasks/store.svelte';
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
      children: [],
      childrenLoaded: true
    });
  });

  it('marks a children-less folder entry (icm_list_dir shape) as NOT loaded — the lazy placeholder', () => {
    const raw = { name: 'Offers', path: 'Offers', type: 'folder', page_count: 2 };

    expect(normalizeIcmNode(raw, 'primary')).toEqual<IcmNode>({
      name: 'Offers',
      path: 'Offers',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 2,
      children: [],
      childrenLoaded: false
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
      children: [],
      childrenLoaded: true
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
      children: [],
      childrenLoaded: true
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
          children: [],
          childrenLoaded: true
        },
        {
          name: 'Page',
          path: 'parent/page',
          mountKey: 'primary',
          type: 'page',
          uri: 'page-uri-123'
        }
      ],
      childrenLoaded: true
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

// `IcmStore` is LAZY (file-browser performance pass): `refetch` fans out
// `list_icms`, then fetches each enabled mount's ROOT level only via
// `icm_list_dir` (plus any deeper dirs already loaded this session);
// `loadDir`/`ensurePathLoaded` fetch deeper levels on demand. The fake
// backend is therefore a per-mount map of dir rel-path → raw entries
// (`''` = the mount root), mirroring `Valea.ICM.list_dir/2`'s shape —
// folder entries carry no `children`.
function fakeApi(
  icms: Array<{ mountKey: string; enabled: boolean; degraded: string | null }>,
  mounts: Record<string, { title: string; dirs: Record<string, any[]> } | undefined>
) {
  const calls: Array<{ mountKey: string; path: string }> = [];
  return {
    calls,
    listIcms: async () => ({ ok: true, data: { icms } }) as ApiResult<any>,
    icmListDir: async (mountKey: string, path: string) => {
      calls.push({ mountKey, path });
      const mount = mounts[mountKey];
      if (!mount) return { ok: false, error: 'outside_workspace' } as ApiResult<any>;
      const entries = mount.dirs[path];
      if (!entries) return { ok: false, error: 'not_found' } as ApiResult<any>;
      return { ok: true, data: { mountKey, title: mount.title, entries } } as ApiResult<any>;
    }
  };
}

const rawFolder = (name: string, path: string, pageCount = 0) => ({
  name,
  path,
  type: 'folder',
  page_count: pageCount
});
const rawPage = (name: string, path: string) => ({ name, path, type: 'page', uri: `icm://${path}` });

describe('IcmStore.refetch (lazy root-level assembly)', () => {
  it('starts unloaded, then fetches ONLY each enabled, non-degraded mount\'s root level', async () => {
    const api = fakeApi(
      [
        { mountKey: 'primary', enabled: true, degraded: null },
        { mountKey: 'clients', enabled: true, degraded: null },
        { mountKey: 'off', enabled: false, degraded: null },
        { mountKey: 'broken', enabled: true, degraded: 'icm.yaml is missing' }
      ],
      {
        primary: {
          title: 'Primary',
          dirs: { '': [rawFolder('Offers', 'Offers', 2), rawPage('Notes', 'Notes.md')] }
        },
        clients: { title: 'Clients', dirs: { '': [] } }
      }
    );
    const store = new IcmStore(api);
    expect(store.loaded).toBe(false);

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(api.calls).toEqual([
      { mountKey: 'primary', path: '' },
      { mountKey: 'clients', path: '' }
    ]);
    expect(store.groups).toEqual([
      {
        mount: 'primary',
        title: 'Primary',
        tree: [
          {
            name: 'Offers',
            path: 'Offers',
            mountKey: 'primary',
            type: 'folder',
            pageCount: 2,
            children: [],
            childrenLoaded: false
          },
          { name: 'Notes', path: 'Notes.md', mountKey: 'primary', type: 'page', uri: 'icm://Notes.md' }
        ]
      },
      { mount: 'clients', title: 'Clients', tree: [] }
    ]);
  });

  it('drops a mount whose root listing fails, keeping the others', async () => {
    const store = new IcmStore(
      fakeApi(
        [
          { mountKey: 'primary', enabled: true, degraded: null },
          { mountKey: 'gone', enabled: true, degraded: null }
        ],
        { primary: { title: 'Primary', dirs: { '': [] } } }
      )
    );

    await store.refetch();

    expect(store.groups.map((g) => g.mount)).toEqual(['primary']);
  });

  it('stays unloaded (and leaves groups untouched) on a mount-list failure', async () => {
    const store = new IcmStore({
      listIcms: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>,
      icmListDir: async () =>
        ({ ok: true, data: { mountKey: 'primary', title: 'Primary', entries: [] } }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });
});

describe('IcmStore.loadDir / ensurePathLoaded (lazy folder loading)', () => {
  const lazyApi = () =>
    fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], {
      primary: {
        title: 'Primary',
        dirs: {
          '': [rawFolder('Offers', 'Offers', 1)],
          Offers: [rawFolder('Archive', 'Offers/Archive'), rawPage('Coaching', 'Offers/Coaching.md')],
          'Offers/Archive': [rawPage('Old', 'Offers/Archive/Old.md')]
        }
      }
    });

  it('loadDir grafts one level into the tree and marks the folder loaded', async () => {
    const store = new IcmStore(lazyApi());
    await store.refetch();

    await store.loadDir('primary', 'Offers');

    const offers = store.groups[0].tree[0];
    expect(offers.childrenLoaded).toBe(true);
    expect(offers.children?.map((c) => c.name)).toEqual(['Archive', 'Coaching']);
    // The freshly revealed subfolder is itself still a lazy placeholder.
    expect(offers.children?.[0].childrenLoaded).toBe(false);
  });

  it('loadDir no-ops for an already-loaded dir and shares one fetch across concurrent calls', async () => {
    const api = lazyApi();
    const store = new IcmStore(api);
    await store.refetch();
    api.calls.length = 0;

    await Promise.all([store.loadDir('primary', 'Offers'), store.loadDir('primary', 'Offers')]);
    await store.loadDir('primary', 'Offers');

    expect(api.calls).toEqual([{ mountKey: 'primary', path: 'Offers' }]);
  });

  it('a dir the backend reports not_found for is marked loaded-and-empty, not left spinning', async () => {
    const api = fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], {
      primary: { title: 'Primary', dirs: { '': [rawFolder('Ghost', 'Ghost')] } }
    });
    const store = new IcmStore(api);
    await store.refetch();

    await store.loadDir('primary', 'Ghost');

    const ghost = store.groups[0].tree[0];
    expect(ghost.childrenLoaded).toBe(true);
    expect(ghost.children).toEqual([]);
  });

  it('refetch re-fetches every loaded dir and re-grafts it (icm_changed freshness), dropping dirs that vanished', async () => {
    const mounts: Record<string, { title: string; dirs: Record<string, any[]> }> = {
      primary: {
        title: 'Primary',
        dirs: {
          '': [rawFolder('Offers', 'Offers', 1), rawFolder('Temp', 'Temp')],
          Offers: [rawPage('Coaching', 'Offers/Coaching.md')],
          Temp: []
        }
      }
    };
    const api = fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], mounts);
    const store = new IcmStore(api);
    await store.refetch();
    await store.loadDir('primary', 'Offers');
    await store.loadDir('primary', 'Temp');

    // Simulate an external change: Temp/ deleted, Offers/ gains a page.
    delete mounts.primary.dirs.Temp;
    mounts.primary.dirs[''] = [rawFolder('Offers', 'Offers', 2)];
    mounts.primary.dirs.Offers = [rawPage('Coaching', 'Offers/Coaching.md'), rawPage('New', 'Offers/New.md')];
    api.calls.length = 0;

    await store.refetch();

    expect(store.loaded).toBe(true);
    const offers = store.groups[0].tree[0];
    expect(offers.childrenLoaded).toBe(true);
    expect(offers.children?.map((c) => c.name)).toEqual(['Coaching', 'New']);
    expect(api.calls).toContainEqual({ mountKey: 'primary', path: 'Offers' });
    expect(api.calls).toContainEqual({ mountKey: 'primary', path: 'Temp' });

    // Temp fell out of the loaded set — the NEXT refetch no longer asks for it.
    api.calls.length = 0;
    await store.refetch();
    expect(api.calls).toContainEqual({ mountKey: 'primary', path: 'Offers' });
    expect(api.calls.some((c) => c.path === 'Temp')).toBe(false);
  });

  it('ensurePathLoaded walks ancestors root-first and returns the node for a deep page', async () => {
    const store = new IcmStore(lazyApi());
    await store.refetch();

    const result = await store.ensurePathLoaded('primary', 'Offers/Archive/Old.md');

    expect(result.status).toBe('found');
    const node = result.status === 'found' ? result.node : undefined;
    expect(node?.type).toBe('page');
    expect(node?.path).toBe('Offers/Archive/Old.md');
    // Both ancestor levels are now genuinely loaded.
    const offers = store.groups[0].tree[0];
    expect(offers.childrenLoaded).toBe(true);
    expect(offers.children?.[0].childrenLoaded).toBe(true);
  });

  it("ensurePathLoaded loads a folder path's OWN listing too, and reports a definitive miss as missing", async () => {
    const store = new IcmStore(lazyApi());
    await store.refetch();

    const result = await store.ensurePathLoaded('primary', 'Offers');
    expect(result.status).toBe('found');
    const folder = result.status === 'found' ? result.node : undefined;
    expect(folder?.type).toBe('folder');
    expect(folder?.childrenLoaded).toBe(true);

    expect(await store.ensurePathLoaded('primary', 'Nope/missing.md')).toEqual({ status: 'missing' });
  });

  it('ensurePathLoaded creates the group when it wins the race against the cold-load refetch', async () => {
    const store = new IcmStore(lazyApi());
    // no refetch first — a deep link's route effect can run before AppFrame's onMount fetch lands

    const result = await store.ensurePathLoaded('primary', 'Offers/Coaching.md');

    expect(result.status === 'found' && result.node.type).toBe('page');
    expect(store.groups.map((g) => g.mount)).toEqual(['primary']);
  });

  it('loadTemplateFolders loads every templates/ folder reachable through loaded levels, to a fixpoint', async () => {
    const api = fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], {
      primary: {
        title: 'Primary',
        dirs: {
          '': [rawFolder('Templates', 'Templates', 1), rawFolder('Clients', 'Clients')],
          Templates: [rawPage('Offer', 'Templates/Offer.md'), rawFolder('templates', 'Templates/templates', 1)],
          'Templates/templates': [rawPage('Nested', 'Templates/templates/Nested.md')]
        }
      }
    });
    const store = new IcmStore(api);
    await store.refetch();

    await store.loadTemplateFolders('primary');

    const templates = store.groups[0].tree[0];
    expect(templates.childrenLoaded).toBe(true);
    const nested = templates.children?.find((c) => c.name === 'templates');
    expect(nested?.childrenLoaded).toBe(true);
    // Non-template folders stay untouched.
    expect(store.groups[0].tree[1].childrenLoaded).toBe(false);
  });
});

// Issue #2 (github): a failed tree fetch was indistinguishable from a deleted
// page — a non-ok mount-list left the loading skeleton up forever, and a
// non-ok root listing silently dropped the whole mount, so every page in it
// rendered "This page doesn't exist anymore." with an empty list pane. These
// tests pin the store-side error states that make those failures observable
// (and retryable) instead.
describe('IcmStore error states (issue #2 — failed fetches must be observable)', () => {
  /** One-mount api whose per-dir listings can be made to fail on demand. */
  function flakyApi(dirs: Record<string, any[]>, failing: Set<string>) {
    return {
      listIcms: async () =>
        ({ ok: true, data: { icms: [{ mountKey: 'primary', enabled: true, degraded: null }] } }) as ApiResult<any>,
      icmListDir: async (mountKey: string, path: string) => {
        if (failing.has(path)) return { ok: false, error: 'channel_timeout' } as ApiResult<any>;
        const entries = dirs[path];
        if (!entries) return { ok: false, error: 'not_found' } as ApiResult<any>;
        return { ok: true, data: { mountKey, title: 'Primary', entries } } as ApiResult<any>;
      }
    };
  }

  const dirs = () => ({
    '': [rawFolder('Offers', 'Offers', 1)],
    Offers: [rawPage('Coaching', 'Offers/Coaching.md')]
  });

  it('records listError when the mount list fails, and clears it on the next successful refetch', async () => {
    let fail = true;
    const store = new IcmStore({
      listIcms: async () =>
        fail
          ? ({ ok: false, error: 'channel_timeout' } as ApiResult<any>)
          : ({ ok: true, data: { icms: [] } } as ApiResult<any>),
      icmListDir: async () => ({ ok: true, data: { title: 'X', entries: [] } }) as ApiResult<any>
    });

    await store.refetch();
    expect(store.listError).toBe('channel_timeout');
    expect(store.loaded).toBe(false);

    fail = false;
    await store.refetch();
    expect(store.listError).toBeNull();
    expect(store.loaded).toBe(true);
  });

  it('records a per-mount error when a root listing fails, alongside dropping the mount from groups', async () => {
    const failing = new Set(['']);
    const store = new IcmStore(flakyApi(dirs(), failing));

    await store.refetch();

    expect(store.groups).toEqual([]);
    expect(store.mountErrors).toEqual({ primary: 'channel_timeout' });
    expect(store.listError).toBeNull();
  });

  it('clears a mount error once its root listing succeeds again', async () => {
    const failing = new Set(['']);
    const store = new IcmStore(flakyApi(dirs(), failing));
    await store.refetch();
    expect(store.mountErrors.primary).toBe('channel_timeout');

    failing.clear();
    await store.refetch();

    expect(store.mountErrors).toEqual({});
    expect(store.groups.map((g) => g.mount)).toEqual(['primary']);
  });

  it('reset clears listError and mountErrors with the rest of the state', async () => {
    const store = new IcmStore(flakyApi(dirs(), new Set([''])));
    await store.refetch();
    expect(store.mountErrors.primary).toBeDefined();

    store.reset();

    expect(store.mountErrors).toEqual({});
    expect(store.listError).toBeNull();
  });

  it('loadDir on the mount root records/clears the mount error too (deep-link race path)', async () => {
    const failing = new Set(['']);
    const store = new IcmStore(flakyApi(dirs(), failing));

    await store.loadDir('primary', '');
    expect(store.mountErrors.primary).toBe('channel_timeout');

    failing.clear();
    await store.loadDir('primary', '');
    expect(store.mountErrors).toEqual({});
  });

  it('ensurePathLoaded reports unavailable (not missing) when an ancestor listing fails transiently, then recovers', async () => {
    const failing = new Set(['Offers']);
    const store = new IcmStore(flakyApi(dirs(), failing));
    await store.refetch();

    expect(await store.ensurePathLoaded('primary', 'Offers/Coaching.md')).toEqual({ status: 'unavailable' });

    failing.clear();
    const recovered = await store.ensurePathLoaded('primary', 'Offers/Coaching.md');
    expect(recovered.status).toBe('found');
    expect(recovered.status === 'found' && recovered.node.path).toBe('Offers/Coaching.md');
  });

  it('ensurePathLoaded reports unavailable when the mount root cannot be listed', async () => {
    const store = new IcmStore(flakyApi(dirs(), new Set([''])));

    expect(await store.ensurePathLoaded('primary', 'Offers/Coaching.md')).toEqual({ status: 'unavailable' });
  });

  it('a refetch whose root listing fails does not leave stale loaded-marks behind — the next ensure re-fetches and reports unavailable, not missing', async () => {
    const failing = new Set<string>();
    const store = new IcmStore(flakyApi(dirs(), failing));
    await store.refetch(); // healthy first load — root marked loaded

    failing.add('');
    await store.refetch(); // mount drops out, error recorded

    // Without clearing the mount's loaded-marks, this would trust the stale
    // root mark, skip the fetch, find nothing, and lie "missing".
    expect(await store.ensurePathLoaded('primary', 'Offers/Coaching.md')).toEqual({ status: 'unavailable' });
  });

  it('ensurePathLoaded reports missing only when the parent listing succeeded without the node', async () => {
    const store = new IcmStore(flakyApi(dirs(), new Set()));
    await store.refetch();

    expect(await store.ensurePathLoaded('primary', 'Offers/Nope.md')).toEqual({ status: 'missing' });
    expect(await store.ensurePathLoaded('primary', 'Ghost/deep.md')).toEqual({ status: 'missing' });
  });
});

describe('IcmStore.refetch (generation argument)', () => {
  it('prefers an explicit generation argument over workspaceStore.generation, threading it into icmListDir too', async () => {
    workspaceStore.generation = 1; // stale — the OUTGOING workspace's generation
    const listIcms = vi.fn(
      async () =>
        ({ ok: true, data: { icms: [{ mountKey: 'legal', enabled: true, degraded: null }] } }) as ApiResult<any>
    );
    const icmListDir = vi.fn(
      async (mountKey: string) => ({ ok: true, data: { mountKey, title: 'Legal', entries: [] } }) as ApiResult<any>
    );
    const store = new IcmStore({ listIcms, icmListDir });

    await store.refetch(7); // the INCOMING workspace's generation, from the event payload

    expect(listIcms).toHaveBeenCalledWith(7);
    expect(icmListDir).toHaveBeenCalledWith('legal', '', 7);
    workspaceStore.generation = null;
  });

  it('falls back to workspaceStore.generation when called bare, unchanged for every other caller', async () => {
    workspaceStore.generation = 42;
    const listIcms = vi.fn(async () => ({ ok: true, data: { icms: [] } }) as ApiResult<any>);
    const store = new IcmStore({ listIcms, icmListDir: async () => ({ ok: true, data: {} }) as ApiResult<any> });

    await store.refetch();

    expect(listIcms).toHaveBeenCalledWith(42);
    workspaceStore.generation = null;
  });

  // Reproduces the actual bug end-to-end with a fake backend that guards
  // generation exactly like `Valea.Api.Icms`'s `check_generation/1` —
  // accepting only the CURRENT (incoming) generation and otherwise returning
  // `workspace_changed`, same as a live switch's stale-generation RPC would.
  it('reproduces the switch-refresh bug: stale workspaceStore.generation is rejected, the event-supplied generation is not', async () => {
    const CURRENT_GENERATION = 7;
    workspaceStore.generation = 1; // stale, from before the switch
    const api = {
      listIcms: vi.fn(async (generation: number) =>
        generation === CURRENT_GENERATION
          ? (({ ok: true, data: { icms: [{ mountKey: 'legal', enabled: true, degraded: null }] } }) as ApiResult<any>)
          : (({ ok: false, error: 'workspace_changed' }) as ApiResult<any>)
      ),
      icmListDir: async (mountKey: string) =>
        ({ ok: true, data: { mountKey, title: 'Legal', entries: [] } }) as ApiResult<any>
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
  it('empties groups, clears loaded, and forgets loaded dirs (a fresh refetch fetches roots only)', async () => {
    const api = fakeApi([{ mountKey: 'primary', enabled: true, degraded: null }], {
      primary: { title: 'Primary', dirs: { '': [rawFolder('Offers', 'Offers')], Offers: [] } }
    });
    const store = new IcmStore(api);
    await store.refetch();
    await store.loadDir('primary', 'Offers');

    store.reset();
    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);

    api.calls.length = 0;
    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(api.calls).toEqual([{ mountKey: 'primary', path: '' }]);
    // The previously loaded folder is back to its lazy placeholder.
    expect(store.groups[0].tree[0].childrenLoaded).toBe(false);
  });

  it('is safe to call before any refetch has resolved', () => {
    const store = new IcmStore(fakeApi([], {}));

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
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
  it('resets all four workspace-scoped stores unconditionally on a close push, without refetching/refreshing any of them', () => {
    const icmReset = vi.spyOn(icmStore, 'reset');
    const mountsReset = vi.spyOn(mountsStore, 'reset');
    const recentReset = vi.spyOn(recentSessionsStore, 'reset');
    const listReset = vi.spyOn(sessionsListStore, 'reset');
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);
    const listRefresh = vi.spyOn(sessionsListStore, 'refresh').mockResolvedValue(undefined);
    const tasksRefresh = vi.spyOn(tasksStore, 'refresh').mockResolvedValue(undefined);

    handleWorkspaceEvent({ open: false });

    expect(tasksRefresh).not.toHaveBeenCalled();
    expect(icmReset).toHaveBeenCalledTimes(1);
    expect(mountsReset).toHaveBeenCalledTimes(1);
    expect(recentReset).toHaveBeenCalledTimes(1);
    // Final review, I3: `sessionsListStore` became a shared singleton in
    // Task 7 (it used to be route-local and disposed on unmount), so it has
    // to be dropped here with its peers or `/chat?all=1` keeps showing the
    // PREVIOUS workspace's sessions across a switch.
    expect(listReset).toHaveBeenCalledTimes(1);
    expect(icmRefetch).not.toHaveBeenCalled();
    expect(mountsRefresh).not.toHaveBeenCalled();
    expect(recentRefresh).not.toHaveBeenCalled();
    expect(listRefresh).not.toHaveBeenCalled();

    icmReset.mockRestore();
    mountsReset.mockRestore();
    recentReset.mockRestore();
    listReset.mockRestore();
    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
    listRefresh.mockRestore();
    tasksRefresh.mockRestore();
  });

  it("on an open push, threads the PUSH'S OWN generation into icmStore.refetch and mountsStore.refresh — not workspaceStore's stale one", () => {
    workspaceStore.generation = 1; // stale — the OUTGOING workspace's generation; workspaceStore.refresh() hasn't resolved yet
    const icmReset = vi.spyOn(icmStore, 'reset');
    const mountsReset = vi.spyOn(mountsStore, 'reset');
    const recentReset = vi.spyOn(recentSessionsStore, 'reset');
    const listReset = vi.spyOn(sessionsListStore, 'reset');
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);
    const listRefresh = vi.spyOn(sessionsListStore, 'refresh').mockResolvedValue(undefined);
    const tasksRefresh = vi.spyOn(tasksStore, 'refresh').mockResolvedValue(undefined);

    handleWorkspaceEvent({ open: true, generation: 7, name: 'Consulting', path: '/ws/consulting' });

    expect(icmReset).toHaveBeenCalledTimes(1);
    expect(mountsReset).toHaveBeenCalledTimes(1);
    expect(recentReset).toHaveBeenCalledTimes(1);
    expect(listReset).toHaveBeenCalledTimes(1);
    expect(icmRefetch).toHaveBeenCalledWith(7);
    expect(mountsRefresh).toHaveBeenCalledWith(7);
    expect(recentRefresh).toHaveBeenCalledTimes(1); // no generation argument — see refreshSidebarProjectStores' doc comment
    // Refreshed, not just cleared: a live switch never remounts `/chat`, so
    // its own `onMount` fetch will not run again (final review, I3).
    expect(listRefresh).toHaveBeenCalledTimes(1);
    expect(listRefresh).toHaveBeenCalledWith(); // plain read, no generation

    icmReset.mockRestore();
    mountsReset.mockRestore();
    recentReset.mockRestore();
    listReset.mockRestore();
    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
    listRefresh.mockRestore();
    tasksRefresh.mockRestore();
    workspaceStore.generation = null;
  });

  it('passes payload.generation through verbatim, even when absent — the workspaceStore.generation fallback lives one layer down, in IcmStore.refetch/MountsStore.refresh themselves (see their own tests)', () => {
    const icmRefetch = vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    const mountsRefresh = vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    const recentRefresh = vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);
    const listRefresh = vi.spyOn(sessionsListStore, 'refresh').mockResolvedValue(undefined);
    const tasksRefresh = vi.spyOn(tasksStore, 'refresh').mockResolvedValue(undefined);

    // Defensive case only — the backend always sends `generation` on an
    // `open: true` push (`WorkspaceEventsChannel.handle_info/2`).
    handleWorkspaceEvent({ open: true });

    expect(icmRefetch).toHaveBeenCalledWith(undefined);
    expect(mountsRefresh).toHaveBeenCalledWith(undefined);
    expect(tasksRefresh).toHaveBeenCalledWith(undefined);

    icmRefetch.mockRestore();
    mountsRefresh.mockRestore();
    recentRefresh.mockRestore();
    listRefresh.mockRestore();
    tasksRefresh.mockRestore();
  });

  // tasks+schedules Task 8: `tasksStore` joins the reset set for the same reason
  // `sessionsListStore` did — a live switch never remounts `/tasks`, so a reader
  // sitting there would keep the previous workspace's ledgers (and `loaded`
  // would stop the route's own `onMount` fetch from running again). Its refresh
  // takes the PUSH's generation, because every ledger read is generation-guarded
  // and `workspaceStore.generation` is stale at this call site.
  it('resets tasksStore on every push and refreshes it with the push’s own generation when open', () => {
    const tasksReset = vi.spyOn(tasksStore, 'reset');
    const tasksRefresh = vi.spyOn(tasksStore, 'refresh').mockResolvedValue(undefined);
    vi.spyOn(icmStore, 'refetch').mockResolvedValue(undefined);
    vi.spyOn(mountsStore, 'refresh').mockResolvedValue(undefined);
    vi.spyOn(recentSessionsStore, 'refresh').mockResolvedValue(undefined);
    vi.spyOn(sessionsListStore, 'refresh').mockResolvedValue(undefined);

    handleWorkspaceEvent({ open: false });
    expect(tasksReset).toHaveBeenCalledTimes(1);
    expect(tasksRefresh).not.toHaveBeenCalled();

    handleWorkspaceEvent({ open: true, generation: 9, name: 'Consulting', path: '/ws/consulting' });
    expect(tasksReset).toHaveBeenCalledTimes(2);
    expect(tasksRefresh).toHaveBeenCalledWith(9);

    vi.restoreAllMocks();
  });
});
