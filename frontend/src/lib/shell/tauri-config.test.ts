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
 *
 * `app.windows` is not the only array caught by that rule. `bundle.externalBin`
 * is one too, and it is the worse of the two: a sidecar added to the base and
 * not restated here is not a build error, it is a Windows installer that ships
 * without the binary and an app that fails when it reaches for it.
 */
const ROOT = join(import.meta.dirname, '../../../../desktop/src-tauri');

type TauriConfig = {
  app?: { windows?: Record<string, unknown>[] };
  bundle?: { targets?: unknown; externalBin?: string[] };
};

function config(file: string): TauriConfig {
  return JSON.parse(readFileSync(join(ROOT, file), 'utf8')) as TauriConfig;
}

function mainWindow(file: string): Record<string, unknown> | null {
  return config(file).app?.windows?.find((w) => w.label === 'main') ?? null;
}

/**
 * Reading a platform window must never fall back to `{}`. An empty object
 * satisfies every "does not contain" assertion below, so a platform file that
 * had lost its window object entirely would read as a clean pass. Throw
 * instead, and name the file while doing it.
 */
function requireMainWindow(file: string): Record<string, unknown> {
  const win = mainWindow(file);
  if (win === null) throw new Error(`${file} declares no window labelled "main"`);
  return win;
}

/** Accepted in any config, effective only on macOS. */
const MACOS_ONLY = ['titleBarStyle', 'hiddenTitle', 'trafficLightPosition'] as const;

/**
 * Keys that are legitimately per-platform, and so are NOT required to match.
 * Everything else in the base window object must be restated identically in
 * every platform file — DERIVED from the base rather than listed here, so a
 * key added to the base is covered the day it is added rather than the day
 * someone remembers to update this file. An allowlist was tried first and had
 * exactly the hole this guard exists to close.
 */
const PER_PLATFORM = new Set<string>([
  'decorations', // the whole point of the platform files
  'shadow', // Linux: unsupported. Windows: `true` gives an undecorated window
  // a 1px white border, and rounded corners on Win11. It is already the serde
  // default (`default_true`), so stating it is documentation, not a change.
  ...MACOS_ONLY
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

  // `base ?? {}` is safe here only because these two assertions defend it: a
  // null base fails the test above, and an empty derived set fails the
  // `length` check rather than making every loop below iterate nothing.
  // Equality alone also can't tell a matching key from an absent one that
  // Tauri will quietly fill with a serde default, so presence is asserted with
  // `Object.hasOwn` before any value is compared.
  it('the derived shared set is non-empty and every key is present in windows', () => {
    const keys = sharedKeys(base ?? {});
    expect(keys.length).toBeGreaterThan(0);

    const win = requireMainWindow('tauri.windows.conf.json');
    for (const key of keys) expect([key, Object.hasOwn(win, key)]).toEqual([key, true]);
  });

  it('windows restates every shared key with the base value', () => {
    const win = requireMainWindow('tauri.windows.conf.json');
    for (const key of sharedKeys(base ?? {})) {
      expect([key, win[key]]).toEqual([key, base?.[key]]);
    }
  });

  // The mirror of the test above, and needed because `sharedKeys` derives from
  // the BASE: a key that exists only in a platform file is in no derived set
  // and would otherwise pass unexamined. Either it belongs in the base and
  // every platform owes it, or it is genuinely per-platform and belongs in
  // `PER_PLATFORM` where the next reader can see it.
  it('windows declares no key that is neither shared nor per-platform', () => {
    const shared = sharedKeys(base ?? {});
    const win = requireMainWindow('tauri.windows.conf.json');
    const undeclared = Object.keys(win).filter(
      (k) => !PER_PLATFORM.has(k) && !shared.includes(k)
    );
    expect(undeclared).toEqual([]);
  });

  it('windows is frameless', () => {
    const win = requireMainWindow('tauri.windows.conf.json');
    expect(win.decorations).toBe(false);
  });

  // Not subsumed by the "no undeclared key" test above, and the reason is worth
  // stating: `PER_PLATFORM` means "may DIFFER between platforms", which is not
  // the same as "may APPEAR in any platform file". The macOS keys sit in that
  // gap — they are per-platform, so the mirror test waves them through, while
  // being meaningless outside macOS. Harmless at runtime, but they would imply
  // the overlay chrome applies here, which is the misreading this whole feature
  // exists to correct.
  it('windows carries no macOS-only keys', () => {
    const win = requireMainWindow('tauri.windows.conf.json');
    for (const key of MACOS_ONLY) expect([key, Object.hasOwn(win, key)]).toEqual([key, false]);
  });
});

describe('the bundle arrays survive the platform merge', () => {
  const base = config('tauri.conf.json');

  // SUBSET, not equality, and deliberately so: `valea-spawn` is a Windows-only
  // Job-Object shim (windows-support spec B2) and has no macOS counterpart, so
  // the Windows list is legitimately longer. What must never happen is the
  // other direction — a sidecar in the base that Windows drops on the floor.
  it('windows restates every base sidecar', () => {
    const win = config('tauri.windows.conf.json');
    expect(base.bundle?.externalBin?.length).toBeGreaterThan(0);
    const shipped = win.bundle?.externalBin ?? [];
    for (const bin of base.bundle?.externalBin ?? []) {
      expect([bin, shipped.includes(bin)]).toEqual([bin, true]);
    }
  });

  // `targets` gets neither a subset nor an equality check: the base is `"all"`
  // and Windows narrows to `["nsis"]` on purpose. The only thing worth holding
  // is that the narrowing is stated — delete the key and the merge silently
  // hands Windows `"all"` instead.
  it('windows states its own bundle targets', () => {
    const win = config('tauri.windows.conf.json');
    expect(win.bundle?.targets).toBeDefined();
  });
});

// `tauri.dev.conf.json` is merged the same way (`--config` in the Justfile, for
// the `Valea Dev` bundle identity). It carries no `app` key today, so there is
// no hazard — this is here so that the day someone adds one, they find out that
// it replaces the whole window array rather than adding to it.
describe('the dev config stays out of the window array', () => {
  it('declares no app.windows', () => {
    expect(config('tauri.dev.conf.json').app?.windows).toBeUndefined();
  });
});
