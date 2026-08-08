import { describe, it, expect, beforeEach, vi } from 'vitest';
import { ComposerOptionsStore } from './composer-options.svelte';

/** In-memory stand-in — the real `persist.ts` guards are exercised by its own suite. */
function fakeStorage() {
  const map = new Map<string, string>();
  return {
    getItem: (k: string) => map.get(k) ?? null,
    setItem: (k: string, v: string) => void map.set(k, v),
    removeItem: (k: string) => void map.delete(k)
  };
}

beforeEach(() => {
  vi.stubGlobal('localStorage', fakeStorage());
});

describe('ComposerOptionsStore', () => {
  it('round-trips a remembered option', () => {
    const store = new ComposerOptionsStore();
    store.remember('ws-1', 'model', 'opus');
    expect(store.remembered('ws-1')).toEqual({ model: 'opus' });
  });

  it('keeps workspaces apart', () => {
    const store = new ComposerOptionsStore();
    store.remember('ws-1', 'permission_mode', 'plan');
    store.remember('ws-2', 'permission_mode', 'acceptEdits');
    expect(store.remembered('ws-1')).toEqual({ permission_mode: 'plan' });
    expect(store.remembered('ws-2')).toEqual({ permission_mode: 'acceptEdits' });
  });

  it('remembers every chip, not just one', () => {
    const store = new ComposerOptionsStore();
    store.remember('ws-1', 'model', 'opus');
    store.remember('ws-1', 'permission_mode', 'plan');
    expect(store.remembered('ws-1')).toEqual({ model: 'opus', permission_mode: 'plan' });
  });

  it('survives a fresh instance reading the same storage', () => {
    new ComposerOptionsStore().remember('ws-1', 'model', 'opus');
    expect(new ComposerOptionsStore().remembered('ws-1')).toEqual({ model: 'opus' });
  });

  it('has nothing to say about an unknown or absent workspace', () => {
    const store = new ComposerOptionsStore();
    expect(store.remembered('nobody')).toEqual({});
    expect(store.remembered(null)).toEqual({});
  });

  it('ignores a null workspace on write rather than inventing a bucket', () => {
    const store = new ComposerOptionsStore();
    store.remember(null, 'model', 'opus');
    expect(store.remembered(null)).toEqual({});
  });

  it('stages a snapshot for one session and hands it over exactly once', () => {
    const store = new ComposerOptionsStore();
    store.remember('ws-1', 'model', 'opus');
    store.stageFor('sess-1', 'ws-1');

    expect(store.takeStaged('sess-1')).toEqual({ model: 'opus' });
    expect(store.takeStaged('sess-1')).toBeNull();
  });

  it('has nothing staged for a session it was never asked about', () => {
    expect(new ComposerOptionsStore().takeStaged('sess-9')).toBeNull();
  });

  it('survives storage that throws on every call', () => {
    vi.stubGlobal('localStorage', {
      getItem: () => { throw new Error('nope'); },
      setItem: () => { throw new Error('nope'); }
    });
    const store = new ComposerOptionsStore();
    expect(() => store.remember('ws-1', 'model', 'opus')).not.toThrow();
    // The write is a no-op (storage stays broken), but the in-memory field
    // `remember` just set is not rolled back on that account — "storage is
    // an enhancement, never a dependency" (persist.ts) means a broken write
    // costs the NEXT app run its memory, not this one.
    expect(store.remembered('ws-1')).toEqual({ model: 'opus' });
  });
});
