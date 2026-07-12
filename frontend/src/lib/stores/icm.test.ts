import { describe, it, expect } from 'vitest';
import { normalizeIcmNode, IcmStore } from './icm.svelte';
import type { IcmNode } from '../shell/nav';
import type { ApiResult } from '../api/client';

describe('normalizeIcmNode', () => {
  it('normalizes snake_case page_count from the wire', () => {
    const raw = {
      name: 'My Folder',
      path: '/my-folder',
      type: 'folder',
      page_count: 3,
      children: []
    };

    const result = normalizeIcmNode(raw);

    expect(result).toEqual<IcmNode>({
      name: 'My Folder',
      path: '/my-folder',
      type: 'folder',
      pageCount: 3,
      children: []
    });
  });

  it('normalizes camelCase pageCount for backward compatibility', () => {
    const raw = {
      name: 'My Folder',
      path: '/my-folder',
      type: 'folder',
      pageCount: 5,
      children: []
    };

    const result = normalizeIcmNode(raw);

    expect(result).toEqual<IcmNode>({
      name: 'My Folder',
      path: '/my-folder',
      type: 'folder',
      pageCount: 5,
      children: []
    });
  });

  it('defaults pageCount to 0 when missing', () => {
    const raw = {
      name: 'Empty Folder',
      path: '/empty',
      type: 'folder',
      children: []
    };

    const result = normalizeIcmNode(raw);

    expect(result).toEqual<IcmNode>({
      name: 'Empty Folder',
      path: '/empty',
      type: 'folder',
      pageCount: 0,
      children: []
    });
  });

  it('normalizes nested children with snake_case counts', () => {
    const raw = {
      name: 'Parent',
      path: '/parent',
      type: 'folder',
      page_count: 2,
      children: [
        {
          name: 'Child Folder',
          path: '/parent/child',
          type: 'folder',
          page_count: 1,
          children: []
        },
        {
          name: 'Page',
          path: '/parent/page',
          type: 'page',
          uri: 'page-uri-123'
        }
      ]
    };

    const result = normalizeIcmNode(raw);

    expect(result).toEqual<IcmNode>({
      name: 'Parent',
      path: '/parent',
      type: 'folder',
      pageCount: 2,
      children: [
        {
          name: 'Child Folder',
          path: '/parent/child',
          type: 'folder',
          pageCount: 1,
          children: []
        },
        {
          name: 'Page',
          path: '/parent/page',
          type: 'page',
          uri: 'page-uri-123'
        }
      ]
    });
  });

  it('normalizes page nodes without pageCount', () => {
    const raw = {
      name: 'My Page',
      path: '/my-page',
      type: 'page',
      uri: 'page-uri-456'
    };

    const result = normalizeIcmNode(raw);

    expect(result).toEqual<IcmNode>({
      name: 'My Page',
      path: '/my-page',
      type: 'page',
      uri: 'page-uri-456'
    });
  });

  it('prefers snake_case over camelCase when both present', () => {
    const raw = {
      name: 'Folder',
      path: '/folder',
      type: 'folder',
      page_count: 10,
      pageCount: 5, // snake_case should win
      children: []
    };

    const result = normalizeIcmNode(raw);

    expect(result.pageCount).toBe(10);
  });
});

// The backend's `icm_tree` RPC (A-T11) returns a GROUPED envelope —
// `{ mounts: [{ mount, title, rootRel, tree }] }` — one entry per enabled
// mount, rather than a single flat `nodes` array. Every fixture below uses
// this shape; `IcmStore.refetch` is what parses it into `groups`.
function groupedResult(mounts: Array<{ mount: string; title: string; rootRel: string; tree: any[] }>): ApiResult<any> {
  return { ok: true, data: { mounts } } as ApiResult<any>;
}

describe('IcmStore.loaded', () => {
  it('starts false before any refetch resolves', () => {
    const store = new IcmStore({ icmTree: async () => groupedResult([]) });

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
    expect(store.nodes).toEqual([]);
  });

  it('flips true after a successful refetch, alongside populated groups', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => groupedResult([{ mount: 'primary', title: 'Primary', rootRel: '', tree: [raw] }])
    });

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);
  });

  it('stays false when the fetch fails, so callers keep showing the loading state', async () => {
    const store = new IcmStore({
      icmTree: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(false);
  });

  it('remains true on subsequent refetches (never reverts to a loading state)', async () => {
    let call = 0;
    const store = new IcmStore({
      icmTree: async () => {
        call += 1;
        return groupedResult([]);
      }
    });

    await store.refetch();
    expect(store.loaded).toBe(true);

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(call).toBe(2);
  });
});

describe('IcmStore.refetch (grouped tree parsing)', () => {
  it('parses each mount entry into a MountGroup with a normalized tree', async () => {
    const rawPrimary = { name: 'Folder A', path: '/folder-a', type: 'folder', page_count: 1, children: [] };
    const rawClients = { name: 'Folder B', path: '/folder-b', type: 'folder', pageCount: 2, children: [] };
    const store = new IcmStore({
      icmTree: async () =>
        groupedResult([
          { mount: 'primary', title: 'Primary', rootRel: '', tree: [rawPrimary] },
          { mount: 'clients', title: 'Clients', rootRel: 'mounts/clients', tree: [rawClients] }
        ])
    });

    await store.refetch();

    expect(store.groups).toEqual([
      {
        mount: 'primary',
        title: 'Primary',
        rootRel: '',
        tree: [{ name: 'Folder A', path: '/folder-a', type: 'folder', pageCount: 1, children: [] }]
      },
      {
        mount: 'clients',
        title: 'Clients',
        rootRel: 'mounts/clients',
        tree: [{ name: 'Folder B', path: '/folder-b', type: 'folder', pageCount: 2, children: [] }]
      }
    ]);
  });

  it('defaults to an empty groups array when `mounts` is missing', async () => {
    const store = new IcmStore({ icmTree: async () => ({ ok: true, data: {} }) as ApiResult<any> });

    await store.refetch();

    expect(store.groups).toEqual([]);
    expect(store.loaded).toBe(true);
  });

  it('leaves groups untouched on failure', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => groupedResult([{ mount: 'primary', title: 'Primary', rootRel: '', tree: [raw] }])
    });
    await store.refetch();

    const failing = new IcmStore({ icmTree: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any> });
    await failing.refetch();

    expect(failing.groups).toEqual([]);
  });
});

describe('IcmStore.nodes (back-compat flatten)', () => {
  it('flattens every mount group\'s tree into a single array, in group order', async () => {
    const rawA = { name: 'A', path: '/a', type: 'folder', page_count: 0, children: [] };
    const rawB = { name: 'B', path: '/b', type: 'page', uri: 'uri-b' };
    const store = new IcmStore({
      icmTree: async () =>
        groupedResult([
          { mount: 'primary', title: 'Primary', rootRel: '', tree: [rawA] },
          { mount: 'clients', title: 'Clients', rootRel: 'mounts/clients', tree: [rawB] }
        ])
    });

    await store.refetch();

    expect(store.nodes).toEqual([
      { name: 'A', path: '/a', type: 'folder', pageCount: 0, children: [] },
      { name: 'B', path: '/b', type: 'page', uri: 'uri-b' }
    ]);
  });

  it('is empty when there are no groups', () => {
    const store = new IcmStore({ icmTree: async () => groupedResult([]) });

    expect(store.nodes).toEqual([]);
  });
});

describe('IcmStore.reset', () => {
  it('empties groups/nodes and clears loaded', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => groupedResult([{ mount: 'primary', title: 'Primary', rootRel: '', tree: [raw] }])
    });

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
    expect(store.nodes).toEqual([]);
  });

  it('is safe to call before any refetch has resolved', () => {
    const store = new IcmStore({ icmTree: async () => groupedResult([]) });

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.groups).toEqual([]);
  });

  it('allows a subsequent refetch to repopulate the tree after reset', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => groupedResult([{ mount: 'primary', title: 'Primary', rootRel: '', tree: [raw] }])
    });

    await store.refetch();
    store.reset();
    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.groups).toHaveLength(1);
  });
});
