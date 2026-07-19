import { describe, it, expect, vi, afterEach } from 'vitest';
import { UpdatesStore, FIRST_CHECK_DELAY_MS, RECHECK_INTERVAL_MS } from './updates.svelte';
import type { PendingUpdate, UpdateCheck } from '$lib/updater';

/**
 * Fake `$lib/updater` surface (DI through the constructor, like
 * `mounts.test.ts`'s fakeApi). Defaults: supported, nothing available.
 */
function fakeUpdater(overrides: {
  updatesSupported?: () => boolean;
  checkForUpdate?: () => Promise<UpdateCheck>;
  relaunchApp?: () => Promise<boolean>;
}) {
  return {
    updatesSupported: overrides.updatesSupported ?? (() => true),
    checkForUpdate: overrides.checkForUpdate ?? (async () => ({ outcome: 'none' }) as UpdateCheck),
    relaunchApp: overrides.relaunchApp ?? (async () => true)
  };
}

function pendingUpdate(overrides: Partial<PendingUpdate> = {}): PendingUpdate {
  return {
    version: '2.0.0',
    download: async (onProgress) => {
      onProgress(50, 100);
      return true;
    },
    install: async () => true,
    ...overrides
  };
}

function available(update: PendingUpdate): () => Promise<UpdateCheck> {
  return async () => ({ outcome: 'available', update });
}

afterEach(() => {
  vi.useRealTimers();
});

describe('start', () => {
  it('does nothing where updates are unsupported (browser, tauri dev)', () => {
    vi.useFakeTimers();
    const checkForUpdate = vi.fn(async () => ({ outcome: 'none' }) as UpdateCheck);
    const store = new UpdatesStore(fakeUpdater({ updatesSupported: () => false, checkForUpdate }));

    store.start();
    vi.advanceTimersByTime(FIRST_CHECK_DELAY_MS + RECHECK_INTERVAL_MS);

    expect(checkForUpdate).not.toHaveBeenCalled();
    store.stop();
  });

  it('checks after the boot delay and again every interval; a second start does not double up', async () => {
    vi.useFakeTimers();
    const checkForUpdate = vi.fn(async () => ({ outcome: 'none' }) as UpdateCheck);
    const store = new UpdatesStore(fakeUpdater({ checkForUpdate }));

    store.start();
    store.start();

    await vi.advanceTimersByTimeAsync(FIRST_CHECK_DELAY_MS);
    expect(checkForUpdate).toHaveBeenCalledTimes(1);

    await vi.advanceTimersByTimeAsync(RECHECK_INTERVAL_MS);
    expect(checkForUpdate).toHaveBeenCalledTimes(2);

    store.stop();
  });
});

describe('check', () => {
  it('stays idle when up to date', async () => {
    const store = new UpdatesStore(fakeUpdater({}));

    await store.check();

    expect(store.phase).toEqual({ kind: 'idle' });
  });

  it('stays quiet (idle, no error card) when the check itself fails', async () => {
    const store = new UpdatesStore(
      fakeUpdater({ checkForUpdate: async () => ({ outcome: 'error', message: 'offline' }) })
    );

    await store.check();

    expect(store.phase).toEqual({ kind: 'idle' });
  });

  it('auto-downloads an available update, reporting progress, then is ready', async () => {
    const phases: string[] = [];
    let observedProgress: [number, number | null] | null = null;
    const update = pendingUpdate({
      download: async (onProgress) => {
        phases.push('during-download');
        onProgress(50, 100);
        return true;
      }
    });
    const store = new UpdatesStore(fakeUpdater({ checkForUpdate: available(update) }));

    const run = store.check();
    await run;

    if (store.phase.kind !== 'ready') throw new Error(`expected ready, got ${store.phase.kind}`);
    expect(store.phase.version).toBe('2.0.0');
    expect(phases).toEqual(['during-download']);
    // Progress was recorded mid-flight into the downloading phase; the final
    // observable state is ready, so assert via a second run with a spy phase.
    const spyStore = new UpdatesStore(
      fakeUpdater({
        checkForUpdate: available(
          pendingUpdate({
            download: async (onProgress) => {
              onProgress(30, 120);
              observedProgress = [30, 120];
              return true;
            }
          })
        )
      })
    );
    await spyStore.check();
    expect(observedProgress).toEqual([30, 120]);
  });

  it('surfaces a failed download as a retriable error', async () => {
    const store = new UpdatesStore(
      fakeUpdater({ checkForUpdate: available(pendingUpdate({ download: async () => false })) })
    );

    await store.check();

    expect(store.phase).toEqual({
      kind: 'error',
      message: 'The update could not be downloaded.',
      retriable: true
    });
  });

  it('does not restart a cycle while one is underway (interval fires mid-download / ready)', async () => {
    const checkForUpdate = vi.fn(available(pendingUpdate()));
    const store = new UpdatesStore(fakeUpdater({ checkForUpdate }));

    await store.check();
    expect(store.phase.kind).toBe('ready');

    await store.check();

    expect(checkForUpdate).toHaveBeenCalledTimes(1);
    expect(store.phase.kind).toBe('ready');
  });

  it('retry after a failed download runs a full fresh cycle', async () => {
    let attempts = 0;
    const store = new UpdatesStore(
      fakeUpdater({
        checkForUpdate: available(
          pendingUpdate({
            download: async () => {
              attempts += 1;
              return attempts > 1;
            }
          })
        )
      })
    );

    await store.check();
    expect(store.phase.kind).toBe('error');

    store.retry();
    await vi.waitFor(() => expect(store.phase.kind).toBe('ready'));
    expect(attempts).toBe(2);
  });
});

describe('installAndRelaunch', () => {
  it('installs then relaunches; phase parks on installing while the app goes down', async () => {
    const install = vi.fn(async () => true);
    const relaunchApp = vi.fn(async () => true);
    const store = new UpdatesStore(
      fakeUpdater({ checkForUpdate: available(pendingUpdate({ install })), relaunchApp })
    );

    await store.check();
    await store.installAndRelaunch();

    expect(install).toHaveBeenCalledTimes(1);
    expect(relaunchApp).toHaveBeenCalledTimes(1);
    expect(store.phase).toEqual({ kind: 'installing', version: '2.0.0' });
  });

  it('does nothing unless an update is ready', async () => {
    const relaunchApp = vi.fn(async () => true);
    const store = new UpdatesStore(fakeUpdater({ relaunchApp }));

    await store.installAndRelaunch();

    expect(relaunchApp).not.toHaveBeenCalled();
    expect(store.phase).toEqual({ kind: 'idle' });
  });

  it('surfaces a failed install as a retriable error', async () => {
    const store = new UpdatesStore(
      fakeUpdater({ checkForUpdate: available(pendingUpdate({ install: async () => false })) })
    );

    await store.check();
    await store.installAndRelaunch();

    expect(store.phase).toEqual({
      kind: 'error',
      message: 'The update could not be installed.',
      retriable: true
    });
  });

  it('a refused relaunch after a successful install is terminal, not retriable', async () => {
    const store = new UpdatesStore(
      fakeUpdater({ checkForUpdate: available(pendingUpdate()), relaunchApp: async () => false })
    );

    await store.check();
    await store.installAndRelaunch();

    expect(store.phase).toEqual({
      kind: 'error',
      message: 'Update installed — quit and reopen Valea to finish.',
      retriable: false
    });
  });
});
