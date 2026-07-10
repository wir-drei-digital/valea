import { describe, it, expect, vi } from 'vitest';
import { PageEditorStore } from './page-editor.svelte';
import type { ApiResult } from '../api/client';

const wait = (ms: number) => new Promise((resolve) => setTimeout(resolve, ms));

type SaveResult = ApiResult<{ hash: string; savedAt: string }>;
type PageResult = ApiResult<{ hash: string }>;

function fakeApi(overrides: {
  saveIcmPage?: (path: string, json: object, baseHash: string) => Promise<SaveResult>;
  icmPage?: (path: string) => Promise<PageResult>;
}) {
  return {
    saveIcmPage:
      overrides.saveIcmPage ??
      (async () => ({ ok: true, data: { hash: 'h2', savedAt: 'ts2' } }) as SaveResult),
    icmPage: overrides.icmPage ?? (async () => ({ ok: true, data: { hash: 'h2' } }) as PageResult)
  };
}

describe('PageEditorStore', () => {
  it('happy path: dirty -> saving -> clean, adopts returned hash + savedAt', async () => {
    const save = vi.fn(async (_path: string, _json: object, _baseHash: string) => ({
      ok: true as const,
      data: { hash: 'h2', savedAt: 'ts2' }
    }));
    const store = new PageEditorStore(fakeApi({ saveIcmPage: save }) as never, '/p', { hash: 'h1' }, { debounceMs: 5 });

    store.noteChange(() => ({ doc: 1 }));
    expect(store.state).toBe('dirty');

    await wait(30);

    expect(save).toHaveBeenCalledWith('/p', { doc: 1 }, 'h1');
    expect(store.state).toBe('clean');
    expect(store.hash).toBe('h2');
    expect(store.savedAt).toBe('ts2');
    expect(store.error).toBe(null);
  });

  it('save returning page_changed moves to conflict', async () => {
    const save = vi.fn(async () => ({ ok: false as const, error: 'page_changed' }));
    const store = new PageEditorStore(fakeApi({ saveIcmPage: save }) as never, '/p', { hash: 'h1' }, { debounceMs: 5 });

    store.noteChange(() => ({ doc: 1 }));
    await wait(30);

    expect(store.state).toBe('conflict');
    expect(store.error).toBe('page_changed');
  });

  it('flush() saves immediately and awaits an in-flight save', async () => {
    let resolveSave: (v: SaveResult) => void = () => {};
    const save = vi.fn(
      () =>
        new Promise<SaveResult>((resolve) => {
          resolveSave = resolve;
        })
    );
    const store = new PageEditorStore(fakeApi({ saveIcmPage: save }) as never, '/p', { hash: 'h1' }, { debounceMs: 1000 });

    store.noteChange(() => ({ doc: 1 }));
    const flushPromise = store.flush();

    expect(store.state).toBe('saving');

    let flushed = false;
    void flushPromise.then(() => {
      flushed = true;
    });

    await wait(10);
    expect(flushed).toBe(false);

    resolveSave({ ok: true, data: { hash: 'h2', savedAt: 'ts2' } });
    await flushPromise;

    expect(flushed).toBe(true);
    expect(store.state).toBe('clean');
    expect(store.hash).toBe('h2');
    expect(save).toHaveBeenCalledTimes(1);
  });

  it('externalChange while clean sets needsReload without touching state', () => {
    const store = new PageEditorStore(fakeApi({}) as never, '/p', { hash: 'h1' }, { debounceMs: 1000 });

    store.externalChange('h2');

    expect(store.needsReload).toBe(true);
    expect(store.state).toBe('clean');
  });

  it('externalChange is a no-op when the hash matches', () => {
    const store = new PageEditorStore(fakeApi({}) as never, '/p', { hash: 'h1' }, { debounceMs: 1000 });

    store.externalChange('h1');

    expect(store.needsReload).toBe(false);
    expect(store.state).toBe('clean');
  });

  it('externalChange while dirty moves to conflict', () => {
    const store = new PageEditorStore(fakeApi({}) as never, '/p', { hash: 'h1' }, { debounceMs: 1000 });

    store.noteChange(() => ({ doc: 1 }));
    store.externalChange('h2');

    expect(store.state).toBe('conflict');
    expect(store.needsReload).toBe(false);
  });

  it('resolveKeepMine refetches the current hash then saves own JSON, landing clean', async () => {
    const icmPage = vi.fn(async () => ({ ok: true as const, data: { hash: 'h3' } }));
    const save = vi.fn(async (_path: string, _json: object, _baseHash: string) => ({
      ok: true as const,
      data: { hash: 'h4', savedAt: 'ts4' }
    }));
    const store = new PageEditorStore(
      fakeApi({ saveIcmPage: save, icmPage }) as never,
      '/p',
      { hash: 'h1' },
      { debounceMs: 1000 }
    );

    store.noteChange(() => ({ doc: 'mine' }));
    store.externalChange('h2');
    expect(store.state).toBe('conflict');

    await store.resolveKeepMine();

    expect(icmPage).toHaveBeenCalledWith('/p');
    expect(save).toHaveBeenCalledWith('/p', { doc: 'mine' }, 'h3');
    expect(store.state).toBe('clean');
    expect(store.hash).toBe('h4');
    expect(store.savedAt).toBe('ts4');
  });

  it('resolveReload adopts the refetched page and clears conflict/needsReload/error', () => {
    const store = new PageEditorStore(fakeApi({}) as never, '/p', { hash: 'h1' }, { debounceMs: 1000 });

    store.noteChange(() => ({ doc: 1 }));
    store.externalChange('h2');
    expect(store.state).toBe('conflict');

    store.resolveReload({ hash: 'h2', savedAt: 'ts2' });

    expect(store.state).toBe('clean');
    expect(store.hash).toBe('h2');
    expect(store.savedAt).toBe('ts2');
    expect(store.needsReload).toBe(false);
    expect(store.error).toBe(null);
  });

  it('a change during saving re-arms the debounce instead of losing the edit', async () => {
    let resolveFirst: (v: SaveResult) => void = () => {};
    const save = vi
      .fn<(path: string, json: object, baseHash: string) => Promise<SaveResult>>()
      .mockImplementationOnce(
        () =>
          new Promise<SaveResult>((resolve) => {
            resolveFirst = resolve;
          })
      )
      .mockImplementationOnce(async () => ({ ok: true, data: { hash: 'h3', savedAt: 'ts3' } }));

    const store = new PageEditorStore(fakeApi({ saveIcmPage: save }) as never, '/p', { hash: 'h1' }, { debounceMs: 5 });

    store.noteChange(() => ({ v: 1 }));
    await wait(15); // debounce fires, first save is now in flight (unresolved)

    expect(store.state).toBe('saving');
    expect(save).toHaveBeenCalledTimes(1);

    // Re-dirty while the first save is in flight.
    store.noteChange(() => ({ v: 2 }));
    expect(store.state).toBe('saving'); // still reflects the in-flight save

    resolveFirst({ ok: true, data: { hash: 'h2', savedAt: 'ts2' } });
    await wait(0);

    // First save resolved but the re-dirty must NOT be discarded as clean.
    expect(store.state).toBe('dirty');
    expect(store.hash).toBe('h2');

    await wait(15); // the re-armed debounce fires, saving the latest edit

    expect(save).toHaveBeenCalledTimes(2);
    expect(save).toHaveBeenNthCalledWith(2, '/p', { v: 2 }, 'h2');
    expect(store.state).toBe('clean');
    expect(store.hash).toBe('h3');
  });

  it('a failed save stays dirty with an error; the next change retries', async () => {
    const save = vi
      .fn<(path: string, json: object, baseHash: string) => Promise<SaveResult>>()
      .mockImplementationOnce(async () => ({ ok: false, error: 'channel_timeout' }))
      .mockImplementationOnce(async () => ({ ok: true, data: { hash: 'h2', savedAt: 'ts2' } }));

    const store = new PageEditorStore(fakeApi({ saveIcmPage: save }) as never, '/p', { hash: 'h1' }, { debounceMs: 5 });

    store.noteChange(() => ({ v: 1 }));
    await wait(20);

    expect(store.state).toBe('dirty');
    expect(store.error).toBe('channel_timeout');
    expect(store.hash).toBe('h1');

    store.noteChange(() => ({ v: 2 }));
    await wait(20);

    expect(save).toHaveBeenCalledTimes(2);
    expect(store.state).toBe('clean');
    expect(store.error).toBe(null);
    expect(store.hash).toBe('h2');
  });
});
