import { describe, expect, it } from 'vitest';
import { readFileSync } from 'node:fs';
import { join } from 'node:path';

/**
 * Tauri merges `tauri.<platform>.conf.json` over `tauri.conf.json` with JSON
 * Merge Patch (RFC 7396), which REPLACES arrays rather than merging them
 * (`tauri-utils/src/config/parse.rs`). `app.windows` is an array, so every
 * platform file has to restate the whole window object — and the duplication
 * that forces is a silent drift hazard on the platforms nobody develops on.
 * This is the guard: change a base window key without changing the platform
 * files and it fails here, on a Mac, rather than in a user's hands.
 */
const ROOT = join(import.meta.dirname, '../../../../desktop/src-tauri');

function mainWindow(file: string): Record<string, unknown> | null {
  const raw = JSON.parse(readFileSync(join(ROOT, file), 'utf8')) as {
    app?: { windows?: Record<string, unknown>[] };
  };
  return raw.app?.windows?.find((w) => w.label === 'main') ?? null;
}

/**
 * Keys that are legitimately per-platform, and so are NOT required to match.
 * Everything else in the base window object must be restated identically in
 * every platform file — DERIVED from the base rather than listed here, so a
 * key added to the base is covered the day it is added rather than the day
 * someone remembers to update this file. An allowlist was tried first and had
 * exactly the hole this guard exists to close.
 */
const PER_PLATFORM = new Set([
  'decorations', // the whole point of the platform files
  'shadow', // Windows-only; Tauri documents it unsupported on Linux
  'titleBarStyle', // the three macOS-only keys below are accepted everywhere
  'hiddenTitle', // and effective only on macOS
  'trafficLightPosition'
]);

function sharedKeys(base: Record<string, unknown>): string[] {
  return Object.keys(base).filter((k) => !PER_PLATFORM.has(k));
}

describe('the main window is restated consistently across platform configs', () => {
  const base = mainWindow('tauri.conf.json');

  it('the base config defines the main window', () => {
    expect(base).not.toBeNull();
  });

  // The two that are load-bearing and whose serde defaults are actively
  // harmful: `create: true` makes Tauri auto-create a window that
  // `build_main_window` then duplicates; `visible: true` shows it before the
  // backend is up.
  it('the base keeps create and visible false', () => {
    expect(base?.create).toBe(false);
    expect(base?.visible).toBe(false);
  });

  // Iterating a derived list is only a guard if the list has something in it,
  // and equality alone can't tell a matching key from an absent one that Tauri
  // will quietly fill with a serde default. So: prove the set is real, then
  // assert PRESENCE with `Object.hasOwn` before asserting the values.
  it('the derived shared set is non-empty and every key is present in windows', () => {
    const keys = sharedKeys(base ?? {});
    expect(keys.length).toBeGreaterThan(0);
    expect(keys).toContain('label');

    const win = mainWindow('tauri.windows.conf.json') ?? {};
    for (const key of keys) expect([key, Object.hasOwn(win, key)]).toEqual([key, true]);
  });

  it('windows restates every shared key with the base value', () => {
    const win = mainWindow('tauri.windows.conf.json');
    expect(win).not.toBeNull();
    for (const key of sharedKeys(base ?? {})) {
      expect([key, win?.[key]]).toEqual([key, base?.[key]]);
    }
  });

  it('windows is frameless', () => {
    const win = mainWindow('tauri.windows.conf.json');
    expect(win?.decorations).toBe(false);
  });

  // macOS-only keys must not leak into a platform file: harmless but
  // misleading, and they would suggest the overlay applies there.
  it('windows carries no macOS-only keys', () => {
    const win = mainWindow('tauri.windows.conf.json') ?? {};
    expect(Object.keys(win)).not.toContain('titleBarStyle');
    expect(Object.keys(win)).not.toContain('hiddenTitle');
    expect(Object.keys(win)).not.toContain('trafficLightPosition');
  });
});
