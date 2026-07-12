import { describe, expect, it, vi } from 'vitest';
import { WorkspaceStore } from './workspace.svelte';

const fakeApi = (open: boolean, generation: number | null = null) => ({
  getWorkspace: async () => ({
    ok: true as const,
    data: { open, name: open ? 'W' : null, path: open ? '/w' : null, generation: open ? generation : null }
  }),
  recentWorkspaces: async () => ({ ok: true as const, data: [] })
});

describe('WorkspaceStore', () => {
  it('starts loading, resolves to none when closed', async () => {
    const store = new WorkspaceStore(fakeApi(false) as never);
    expect(store.state).toBe('loading');
    await store.refresh();
    expect(store.state).toBe('none');
  });

  it('resolves to open with name', async () => {
    const store = new WorkspaceStore(fakeApi(true) as never);
    await store.refresh();
    expect(store.state).toBe('open');
    expect(store.name).toBe('W');
  });

  it('captures generation from load and updates it on a subsequent workspace event refresh', async () => {
    const api = fakeApi(true, 1);
    const store = new WorkspaceStore(api as never);

    await store.refresh();
    expect(store.generation).toBe(1);

    // A `workspace` channel push (e.g. another window switched workspaces)
    // triggers a fresh `refresh()` — the RPC's `generation` should replace
    // the stale one rather than sticking at its first-load value.
    (api as any).getWorkspace = async () => ({
      ok: true as const,
      data: { open: true, name: 'W', path: '/w', generation: 2 }
    });
    await store.refresh();
    expect(store.generation).toBe(2);
  });

  it('clears generation when the workspace closes', async () => {
    const store = new WorkspaceStore(fakeApi(false) as never);
    await store.refresh();
    expect(store.generation).toBeNull();
  });
});

describe('WorkspaceStore.adopt', () => {
  it('calls api.adoptWorkspace with parentDir/name/icmSourcePath, then refreshes on success', async () => {
    const api = fakeApi(true, 1) as any;
    api.adoptWorkspace = vi.fn(async () => ({ ok: true as const, data: {} }));
    const store = new WorkspaceStore(api as never);

    const result = await store.adopt('/Users/mara', 'Acme', '/Users/mara/Old Notes');

    expect(result).toEqual({ ok: true });
    expect(api.adoptWorkspace).toHaveBeenCalledWith('/Users/mara', 'Acme', '/Users/mara/Old Notes');
    expect(store.state).toBe('open');
  });

  it('surfaces the adoptWorkspace error without refreshing', async () => {
    const api = fakeApi(false) as any;
    api.adoptWorkspace = vi.fn(async () => ({ ok: false as const, error: 'source_is_workspace' }));
    const store = new WorkspaceStore(api as never);

    const result = await store.adopt('/Users/mara', 'Acme', '/Users/mara/Already A Workspace');

    expect(result).toEqual({ ok: false, error: 'source_is_workspace' });
  });
});

describe('WorkspaceStore.switchTo', () => {
  function fakeApiWithOpen(generation = 3) {
    const api = fakeApi(true, generation) as any;
    api.openWorkspace = vi.fn(async () => ({ ok: true as const, data: {} }));
    return api;
  }

  it('switches with no flush hook (clean editor) — opens straight away', async () => {
    const api = fakeApiWithOpen();
    const store = new WorkspaceStore(api as never);

    const result = await store.switchTo('/other');

    expect(result).toEqual({ ok: true });
    expect(api.openWorkspace).toHaveBeenCalledWith('/other');
    expect(store.state).toBe('open');
  });

  it('switches with a dirty editor that flushes OK — flush runs before open', async () => {
    const api = fakeApiWithOpen();
    const store = new WorkspaceStore(api as never);
    const order: string[] = [];
    const onBeforeMutate = vi.fn(async () => {
      order.push('flush');
    });
    api.openWorkspace = vi.fn(async () => {
      order.push('open');
      return { ok: true as const, data: {} };
    });

    const result = await store.switchTo('/other', onBeforeMutate);

    expect(result).toEqual({ ok: true });
    expect(onBeforeMutate).toHaveBeenCalledTimes(1);
    expect(order).toEqual(['flush', 'open']);
  });

  it('a failed flush aborts the switch with unsaved_changes and never calls openWorkspace', async () => {
    const api = fakeApiWithOpen();
    const store = new WorkspaceStore(api as never);
    const onBeforeMutate = vi.fn(async () => {
      throw new Error('unsaved_changes');
    });

    const result = await store.switchTo('/other', onBeforeMutate);

    expect(result).toEqual({ ok: false, error: 'unsaved_changes' });
    expect(api.openWorkspace).not.toHaveBeenCalled();
    // No refresh happened either — the store's prior state is untouched.
    expect(store.state).toBe('loading');
  });

  it('surfaces the openWorkspace error when the flush succeeds but opening fails', async () => {
    const api = fakeApiWithOpen();
    api.openWorkspace = vi.fn(async () => ({ ok: false as const, error: 'not_a_workspace' }));
    const store = new WorkspaceStore(api as never);

    const result = await store.switchTo('/other', async () => {});

    expect(result).toEqual({ ok: false, error: 'not_a_workspace' });
  });
});
