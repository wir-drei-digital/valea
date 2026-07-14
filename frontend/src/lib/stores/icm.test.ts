import { describe, it, expect } from 'vitest';
import { normalizeIcmNode, IcmStore } from './icm.svelte';
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
