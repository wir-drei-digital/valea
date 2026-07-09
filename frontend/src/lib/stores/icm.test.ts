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

describe('IcmStore.loaded', () => {
  it('starts false before any refetch resolves', () => {
    const store = new IcmStore({ icmTree: async () => ({ ok: true, data: { nodes: [] } }) as ApiResult<any> });

    expect(store.loaded).toBe(false);
    expect(store.nodes).toEqual([]);
  });

  it('flips true after a successful refetch, alongside populated nodes', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => ({ ok: true, data: { nodes: [raw] } }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.nodes).toHaveLength(1);
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
        return { ok: true, data: { nodes: [] } } as ApiResult<any>;
      }
    });

    await store.refetch();
    expect(store.loaded).toBe(true);

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(call).toBe(2);
  });
});

describe('IcmStore.reset', () => {
  it('empties nodes and clears loaded', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => ({ ok: true, data: { nodes: [raw] } }) as ApiResult<any>
    });

    await store.refetch();
    expect(store.loaded).toBe(true);
    expect(store.nodes).toHaveLength(1);

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.nodes).toEqual([]);
  });

  it('is safe to call before any refetch has resolved', () => {
    const store = new IcmStore({ icmTree: async () => ({ ok: true, data: { nodes: [] } }) as ApiResult<any> });

    store.reset();

    expect(store.loaded).toBe(false);
    expect(store.nodes).toEqual([]);
  });

  it('allows a subsequent refetch to repopulate the tree after reset', async () => {
    const raw = { name: 'Folder', path: '/folder', type: 'folder', page_count: 0, children: [] };
    const store = new IcmStore({
      icmTree: async () => ({ ok: true, data: { nodes: [raw] } }) as ApiResult<any>
    });

    await store.refetch();
    store.reset();
    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.nodes).toHaveLength(1);
  });
});
