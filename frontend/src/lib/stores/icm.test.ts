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

  it('preserves file leaves (A-T15 fix wave) — type "file" with the ext passed through', () => {
    const raw = { name: 'X.pdf', path: 'mounts/primary/Offers/X.pdf', type: 'file', ext: '.pdf' };

    expect(normalizeIcmNode(raw)).toEqual<IcmNode>({
      name: 'X.pdf',
      path: 'mounts/primary/Offers/X.pdf',
      type: 'file',
      ext: '.pdf'
    });
  });

  it('normalizes file leaves nested inside folder children', () => {
    const raw = {
      name: 'Offers',
      path: 'mounts/primary/Offers',
      type: 'folder',
      page_count: 1,
      children: [
        { name: 'Founder Coaching', path: 'mounts/primary/Offers/Founder Coaching.md', type: 'page', uri: 'u' },
        { name: 'logo.png', path: 'mounts/primary/Offers/logo.png', type: 'file', ext: '.png' }
      ]
    };

    const result = normalizeIcmNode(raw);

    expect(result.children?.[1]).toEqual<IcmNode>({
      name: 'logo.png',
      path: 'mounts/primary/Offers/logo.png',
      type: 'file',
      ext: '.png'
    });
  });

  it('still coerces an unknown type to page (defensive default, unchanged)', () => {
    const raw = { name: 'Mystery', path: '/mystery', type: 'something_else', uri: 'u' };

    expect(normalizeIcmNode(raw).type).toBe('page');
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

  it('parses an EXTERNAL mount group (A2-T5b) — rootRel and every node path stay the absolute physical vocabulary the backend sent, unmodified', async () => {
    const extPage = {
      name: 'X',
      path: '/Users/dev/ext-mount/Offers/X.md',
      type: 'page',
      uri: 'icm:///Users/dev/ext-mount/Offers/X.md'
    };
    const extFolder = {
      name: 'Offers',
      path: '/Users/dev/ext-mount/Offers',
      type: 'folder',
      page_count: 1,
      children: [extPage]
    };
    const store = new IcmStore({
      icmTree: async () =>
        groupedResult([
          { mount: 'primary', title: 'Primary', rootRel: 'mounts/primary', tree: [] },
          { mount: 'ext', title: 'Ext', rootRel: '/Users/dev/ext-mount', tree: [extFolder] }
        ])
    });

    await store.refetch();

    const extGroup = store.groups.find((g) => g.mount === 'ext');
    expect(extGroup?.rootRel).toBe('/Users/dev/ext-mount');
    expect(extGroup?.tree[0]).toEqual({
      name: 'Offers',
      path: '/Users/dev/ext-mount/Offers',
      type: 'folder',
      pageCount: 1,
      children: [
        {
          name: 'X',
          path: '/Users/dev/ext-mount/Offers/X.md',
          type: 'page',
          uri: 'icm:///Users/dev/ext-mount/Offers/X.md'
        }
      ]
    });
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

describe('IcmStore.reset', () => {
  it('empties groups and clears loaded', async () => {
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
