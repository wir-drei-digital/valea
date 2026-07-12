import { describe, it, expect } from 'vitest';
import { WorkflowsStore } from './workflows.svelte';
import type { ApiResult } from '../api/client';

describe('WorkflowsStore.refetch', () => {
  it('populates list and flips loaded on success', async () => {
    const raw = [
      {
        path: '/wf/reply.md',
        name: 'Reply drafting',
        enabled: true,
        riskLevel: 'low',
        mount: 'Primary'
      }
    ];
    const store = new WorkflowsStore({
      listWorkflows: async () => ({ ok: true, data: { workflows: raw } }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(true);
    expect(store.list).toEqual(raw);
  });

  it('leaves list/loaded untouched on failure', async () => {
    const store = new WorkflowsStore({
      listWorkflows: async () => ({ ok: false, error: 'unknown_error' }) as ApiResult<any>
    });

    await store.refetch();

    expect(store.loaded).toBe(false);
    expect(store.list).toEqual([]);
  });
});
