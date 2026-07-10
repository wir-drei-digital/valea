import { describe, expect, it } from 'vitest';
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
