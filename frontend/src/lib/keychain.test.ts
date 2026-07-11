import { describe, it, expect, vi, beforeEach, afterEach } from 'vitest';

// `@tauri-apps/api/core` is a third-party package, not one of this repo's
// stores/singletons — mocking it here (rather than the internal module
// under test) is what lets the "desktop path" tests below drive
// `keychain.ts`'s real `invoke(...)` call sites without an actual Tauri
// webview bridge.
vi.mock('@tauri-apps/api/core', () => ({ invoke: vi.fn() }));

import { invoke } from '@tauri-apps/api/core';
import { inDesktop, keychainSet, keychainGet, keychainDelete } from './keychain';

describe('inDesktop', () => {
  it('is false when there is no Tauri global (browser/vitest environment)', () => {
    expect(inDesktop()).toBe(false);
  });
});

describe('browser fallback (no Tauri global) — never throws', () => {
  it('keychainSet resolves false', async () => {
    await expect(keychainSet('ws-1', 'mara@example.com', 'hunter2')).resolves.toBe(false);
  });

  it('keychainGet resolves null', async () => {
    await expect(keychainGet('ws-1', 'mara@example.com')).resolves.toBeNull();
  });

  it('keychainDelete resolves without a value', async () => {
    await expect(keychainDelete('ws-1', 'mara@example.com')).resolves.toBeUndefined();
  });

  it('never calls the Tauri invoke bridge', async () => {
    await keychainSet('ws-1', 'mara@example.com', 'hunter2');
    await keychainGet('ws-1', 'mara@example.com');
    await keychainDelete('ws-1', 'mara@example.com');
    expect(invoke).not.toHaveBeenCalled();
  });
});

describe('desktop path (Tauri global present)', () => {
  beforeEach(() => {
    vi.stubGlobal('window', { __TAURI_INTERNALS__: {} });
    vi.mocked(invoke).mockReset();
  });

  afterEach(() => {
    vi.unstubAllGlobals();
  });

  it('inDesktop is true', () => {
    expect(inDesktop()).toBe(true);
  });

  it('keychainSet invokes mail_secret_set with the exact args and resolves true', async () => {
    vi.mocked(invoke).mockResolvedValueOnce(undefined);

    const ok = await keychainSet('ws-1', 'mara@example.com', 'hunter2');

    expect(invoke).toHaveBeenCalledWith('mail_secret_set', {
      workspaceId: 'ws-1',
      username: 'mara@example.com',
      secret: 'hunter2'
    });
    expect(ok).toBe(true);
  });

  it('keychainSet resolves false (never throws) when the command rejects', async () => {
    vi.mocked(invoke).mockRejectedValueOnce(new Error('keychain unavailable'));

    await expect(keychainSet('ws-1', 'mara@example.com', 'hunter2')).resolves.toBe(false);
  });

  it('keychainGet invokes mail_secret_get and returns the stored secret', async () => {
    vi.mocked(invoke).mockResolvedValueOnce('hunter2');

    const secret = await keychainGet('ws-1', 'mara@example.com');

    expect(invoke).toHaveBeenCalledWith('mail_secret_get', { workspaceId: 'ws-1', username: 'mara@example.com' });
    expect(secret).toBe('hunter2');
  });

  it('keychainGet returns null when nothing is stored', async () => {
    vi.mocked(invoke).mockResolvedValueOnce(null);

    await expect(keychainGet('ws-1', 'mara@example.com')).resolves.toBeNull();
  });

  it('keychainGet returns null (never throws) when the command rejects', async () => {
    vi.mocked(invoke).mockRejectedValueOnce(new Error('keychain unavailable'));

    await expect(keychainGet('ws-1', 'mara@example.com')).resolves.toBeNull();
  });

  it('keychainDelete invokes mail_secret_delete with the exact args', async () => {
    vi.mocked(invoke).mockResolvedValueOnce(undefined);

    await keychainDelete('ws-1', 'mara@example.com');

    expect(invoke).toHaveBeenCalledWith('mail_secret_delete', { workspaceId: 'ws-1', username: 'mara@example.com' });
  });

  it('keychainDelete never throws when the command rejects', async () => {
    vi.mocked(invoke).mockRejectedValueOnce(new Error('keychain unavailable'));

    await expect(keychainDelete('ws-1', 'mara@example.com')).resolves.toBeUndefined();
  });
});
