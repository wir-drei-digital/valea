import { describe, it, expect } from 'vitest';
import { normalizeIcmNode } from './icm.svelte';
import type { IcmNode } from '../shell/nav';

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
