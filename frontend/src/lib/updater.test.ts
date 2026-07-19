import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// Third-party Tauri plugin packages mocked (not the module under test) so
// the "desktop path" tests drive `updater.ts`'s real call sites without a
// Tauri webview bridge — same setup as keychain.test.ts.
vi.mock('@tauri-apps/plugin-updater', () => ({ check: vi.fn() }));
vi.mock('@tauri-apps/plugin-process', () => ({ relaunch: vi.fn() }));

import { check, type Update } from '@tauri-apps/plugin-updater';
import { relaunch } from '@tauri-apps/plugin-process';
import { checkForUpdate, relaunchApp, updatesSupported } from './updater';

/** A fake plugin `Update` with just the surface `updater.ts` touches. */
function fakeUpdate(overrides: Partial<Update> = {}): Update {
  return {
    version: '9.9.9',
    download: vi.fn(async () => {}),
    install: vi.fn(async () => {}),
    ...overrides
  } as unknown as Update;
}

describe('browser fallback (no Tauri global) — never throws, never touches the bridge', () => {
  it('updatesSupported is false', () => {
    expect(updatesSupported()).toBe(false);
  });

  it('checkForUpdate resolves unsupported without calling check', async () => {
    await expect(checkForUpdate()).resolves.toEqual({ outcome: 'unsupported' });
    expect(check).not.toHaveBeenCalled();
  });

  it('relaunchApp resolves false without calling relaunch', async () => {
    await expect(relaunchApp()).resolves.toBe(false);
    expect(relaunch).not.toHaveBeenCalled();
  });
});

describe('desktop path (Tauri global present, prod build)', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { __TAURI_INTERNALS__: {} });
    vi.stubEnv('PROD', true);
    vi.mocked(check).mockReset();
    vi.mocked(relaunch).mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
    vi.unstubAllEnvs();
  });

  it('updatesSupported is true', () => {
    expect(updatesSupported()).toBe(true);
  });

  it('updatesSupported stays false in a dev build (tauri dev)', () => {
    vi.stubEnv('PROD', false);
    expect(updatesSupported()).toBe(false);
  });

  it('resolves none when the app is current', async () => {
    vi.mocked(check).mockResolvedValueOnce(null);

    await expect(checkForUpdate()).resolves.toEqual({ outcome: 'none' });
  });

  it('resolves error (never throws) when the check fails', async () => {
    vi.mocked(check).mockRejectedValueOnce(new Error('endpoint unreachable'));

    await expect(checkForUpdate()).resolves.toEqual({
      outcome: 'error',
      message: 'endpoint unreachable'
    });
  });

  it('wraps an available update with its version', async () => {
    vi.mocked(check).mockResolvedValueOnce(fakeUpdate({ version: '1.2.3' }));

    const result = await checkForUpdate();

    expect(result.outcome).toBe('available');
    if (result.outcome === 'available') expect(result.update.version).toBe('1.2.3');
  });

  it('download normalizes plugin events into cumulative (downloaded, total) progress', async () => {
    const download = vi.fn(async (onEvent: (e: unknown) => void) => {
      onEvent({ event: 'Started', data: { contentLength: 100 } });
      onEvent({ event: 'Progress', data: { chunkLength: 40 } });
      onEvent({ event: 'Progress', data: { chunkLength: 25 } });
      onEvent({ event: 'Finished' });
    });
    vi.mocked(check).mockResolvedValueOnce(fakeUpdate({ download } as Partial<Update>));

    const result = await checkForUpdate();
    if (result.outcome !== 'available') throw new Error('expected available');

    const seen: Array<[number, number | null]> = [];
    const ok = await result.update.download((downloaded, total) => seen.push([downloaded, total]));

    expect(ok).toBe(true);
    expect(seen).toEqual([
      [40, 100],
      [65, 100]
    ]);
  });

  it('download reports null total when the server sent no content length', async () => {
    const download = vi.fn(async (onEvent: (e: unknown) => void) => {
      onEvent({ event: 'Started', data: {} });
      onEvent({ event: 'Progress', data: { chunkLength: 10 } });
    });
    vi.mocked(check).mockResolvedValueOnce(fakeUpdate({ download } as Partial<Update>));

    const result = await checkForUpdate();
    if (result.outcome !== 'available') throw new Error('expected available');

    const seen: Array<[number, number | null]> = [];
    await result.update.download((downloaded, total) => seen.push([downloaded, total]));

    expect(seen).toEqual([[10, null]]);
  });

  it('download resolves false (never throws) when the plugin download fails', async () => {
    const download = vi.fn(async () => {
      throw new Error('disk full');
    });
    vi.mocked(check).mockResolvedValueOnce(fakeUpdate({ download } as Partial<Update>));

    const result = await checkForUpdate();
    if (result.outcome !== 'available') throw new Error('expected available');

    await expect(result.update.download(() => {})).resolves.toBe(false);
  });

  it('install resolves true on success, false (never throws) on failure', async () => {
    const failing = fakeUpdate({
      install: vi.fn(async () => {
        throw new Error('signature mismatch');
      })
    } as Partial<Update>);
    vi.mocked(check).mockResolvedValueOnce(fakeUpdate()).mockResolvedValueOnce(failing);

    const first = await checkForUpdate();
    if (first.outcome !== 'available') throw new Error('expected available');
    await expect(first.update.install()).resolves.toBe(true);

    const second = await checkForUpdate();
    if (second.outcome !== 'available') throw new Error('expected available');
    await expect(second.update.install()).resolves.toBe(false);
  });

  it('relaunchApp resolves true on success, false (never throws) on failure', async () => {
    vi.mocked(relaunch).mockResolvedValueOnce(undefined);
    await expect(relaunchApp()).resolves.toBe(true);

    vi.mocked(relaunch).mockRejectedValueOnce(new Error('no permission'));
    await expect(relaunchApp()).resolves.toBe(false);
  });
});
