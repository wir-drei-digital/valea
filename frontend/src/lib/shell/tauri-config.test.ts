import { describe, expect, it } from 'vitest';
import { readdirSync, readFileSync } from 'node:fs';
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

/**
 * Every platform file that overrides the base window. The restatement rule is
 * a property of the MERGE, not of any one platform, so the expectations below
 * are parameterised over this list rather than written out per file: a third
 * platform costs one entry here instead of five near-identical tests, and it
 * cannot be added while quietly skipping one of them.
 *
 * That last guarantee only holds for a platform someone remembers to add HERE,
 * which is why `guards every platform config on disk` reads the directory
 * instead. What is genuinely per-platform — `shadow`, and the bundle `targets`
 * further down — stays written out on its own.
 */
const PLATFORM_FILES = ['tauri.windows.conf.json', 'tauri.linux.conf.json'] as const;

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

  // `base ?? {}` is safe in every test below only because two assertions
  // defend it: a null base fails the test above, and an empty derived set
  // fails this `length` check rather than making every loop iterate nothing
  // and pass.
  it('the derived shared set is non-empty', () => {
    expect(sharedKeys(base ?? {}).length).toBeGreaterThan(0);
  });

  // `PLATFORM_FILES` is hand-maintained, and Vitest's `each` is a bare
  // `cases.forEach` (`@vitest/runner`), so an empty list registers ZERO tests
  // and reports success — a vanished list looks exactly like a passing one.
  // This is the one test that reads the DIRECTORY rather than the list. It
  // fails if the list is emptied, and — the failure that will actually happen —
  // if a `tauri.macos.conf.json` ever lands on disk without being added to it,
  // where it would silently inherit none of the checks below.
  //
  // `tauri.conf.json` cannot match: the pattern requires a platform segment
  // BETWEEN `tauri.` and `.conf.json`. `tauri.dev.conf.json` does match and is
  // excluded by name — it is not a platform file (the Justfile passes it with
  // `--config`, for the `Valea Dev` bundle identity) and it has a describe of
  // its own at the foot of this file.
  it('guards every platform config on disk', () => {
    const onDisk = readdirSync(ROOT).filter(
      (f) => /^tauri\.[a-z]+\.conf\.json$/.test(f) && f !== 'tauri.dev.conf.json'
    );
    expect(onDisk.sort()).toEqual([...PLATFORM_FILES].sort());
  });

  // Equality alone can't tell a matching key from an absent one that Tauri
  // will quietly fill with a serde default, so presence is asserted with
  // `Object.hasOwn` before any value is compared.
  it.each(PLATFORM_FILES)('%s declares every shared key', (file) => {
    const win = requireMainWindow(file);
    for (const key of sharedKeys(base ?? {})) {
      expect([key, Object.hasOwn(win, key)]).toEqual([key, true]);
    }
  });

  it.each(PLATFORM_FILES)('%s restates every shared key with the base value', (file) => {
    const win = requireMainWindow(file);
    for (const key of sharedKeys(base ?? {})) {
      expect([key, win[key]]).toEqual([key, base?.[key]]);
    }
  });

  // The mirror of the test above, and needed because `sharedKeys` derives from
  // the BASE: a key that exists only in a platform file is in no derived set
  // and would otherwise pass unexamined. Either it belongs in the base and
  // every platform owes it, or it is genuinely per-platform and belongs in
  // `PER_PLATFORM` where the next reader can see it.
  it.each(PLATFORM_FILES)('%s declares no key that is neither shared nor per-platform', (file) => {
    const shared = sharedKeys(base ?? {});
    const win = requireMainWindow(file);
    const undeclared = Object.keys(win).filter(
      (k) => !PER_PLATFORM.has(k) && !shared.includes(k)
    );
    expect(undeclared).toEqual([]);
  });

  it.each(PLATFORM_FILES)('%s is frameless', (file) => {
    expect(requireMainWindow(file).decorations).toBe(false);
  });

  // Not subsumed by the "no undeclared key" test above, and the reason is worth
  // stating: `PER_PLATFORM` means "may DIFFER between platforms", which is not
  // the same as "may APPEAR in any platform file". The macOS keys sit in that
  // gap — they are per-platform, so the mirror test waves them through, while
  // being meaningless outside macOS. Harmless at runtime, but they would imply
  // the overlay chrome applies here, which is the misreading this whole feature
  // exists to correct.
  it.each(PLATFORM_FILES)('%s carries no macOS-only keys', (file) => {
    const win = requireMainWindow(file);
    for (const key of MACOS_ONLY) expect([key, Object.hasOwn(win, key)]).toEqual([key, false]);
  });

  // `shadow` is the one window key the two frameless platforms answer
  // differently, so it is the one that cannot be parameterised — and being in
  // `PER_PLATFORM` exempts it from BOTH the equality check and its mirror.
  // Without the two tests below it could be deleted from either file and the
  // suite would stay green while the comments here went on describing it.
  //
  // Tauri documents `shadow` as unsupported on Linux, and CSS cannot stand in:
  // a webview's box-shadow is clipped to the native window bounds and
  // `border-radius` does not shape the GDK surface. Stating it there would be a
  // claim the platform ignores.
  it('linux asks for no shadow', () => {
    expect(requireMainWindow('tauri.linux.conf.json').shadow).toBeUndefined();
  });

  // The Windows half pins the STATEMENT, not the behaviour: `shadow` is already
  // the serde default (`default_true`), so deleting the key would change
  // nothing about the window. What it would change is that the undecorated
  // window's 1px border and its Win11 rounded corners would read as an accident
  // of a default rather than as something chosen — and this file's own
  // `PER_PLATFORM` comment says they were chosen.
  it('windows states its shadow', () => {
    expect(requireMainWindow('tauri.windows.conf.json').shadow).toBe(true);
  });
});

describe('the bundle arrays survive the platform merge', () => {
  const base = config('tauri.conf.json');

  it('the base declares at least one sidecar', () => {
    expect(base.bundle?.externalBin?.length).toBeGreaterThan(0);
  });

  // SUBSET, not equality, and deliberately so: `valea-spawn` is a Windows-only
  // Job-Object shim (windows-support spec B2) and has no macOS counterpart, so
  // the Windows list is legitimately longer. What must never happen is the
  // other direction — a sidecar in the base that a platform drops on the floor.
  //
  // Falling back to the BASE list, not to `[]`, is what lets this run over every
  // platform: Merge Patch recurses into objects and only replaces arrays, so a
  // file that states no `bundle` (Linux today) or a `bundle` without
  // `externalBin` inherits the base list intact, and must pass. The day Linux
  // states `targets: ["deb", "appimage"]` and someone adds `externalBin`
  // alongside it, the array IS replaced and this starts holding it to the base —
  // which is the failure this file's header calls out as the worse of the two,
  // because an installer missing a sidecar is not a build error.
  it.each(PLATFORM_FILES)('%s ships every base sidecar', (file) => {
    const declared = base.bundle?.externalBin ?? [];
    const shipped = config(file).bundle?.externalBin ?? declared;
    for (const bin of declared) {
      expect([bin, shipped.includes(bin)]).toEqual([bin, true]);
    }
  });

  // `targets` gets neither a subset nor an equality check, and stays
  // Windows-only: the base is `"all"` and Windows narrows to `["nsis"]` on
  // purpose, while Linux WANTS the base `"all"` (deb, rpm, AppImage) and so
  // states no bundle block at all — there is nothing to pin there. The only
  // thing worth holding is that the narrowing is stated: delete the key and the
  // merge silently hands Windows `"all"` instead.
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
