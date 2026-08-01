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
 * Keys every platform must agree on. Deliberately EXCLUDES the ones that are
 * legitimately per-platform: `decorations`, `shadow`, and the three macOS-only
 * keys (`titleBarStyle`, `hiddenTitle`, `trafficLightPosition`).
 */
const SHARED = [
  'label',
  'create',
  'title',
  'width',
  'height',
  'minWidth',
  'minHeight',
  'center',
  'resizable',
  'fullscreen',
  'visible'
] as const;

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

  it('windows restates every shared key with the base value', () => {
    const win = mainWindow('tauri.windows.conf.json');
    expect(win).not.toBeNull();
    for (const key of SHARED) expect([key, win?.[key]]).toEqual([key, base?.[key]]);
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
