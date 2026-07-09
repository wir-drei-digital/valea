import { describe, expect, it } from 'vitest';
import { WorkspaceStore } from './workspace.svelte';

const fakeApi = (open: boolean) => ({
  getWorkspace: async () => ({ ok: true as const, data: { open, name: open ? 'W' : null, path: open ? '/w' : null } }),
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
});
