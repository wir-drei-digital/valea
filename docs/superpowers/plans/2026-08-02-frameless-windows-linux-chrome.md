# Frameless Window Chrome for Windows and Linux — Implementation Plan

> ## ✅ EXECUTED 2026-08-02 — DO NOT RE-RUN THIS PLAN AS WRITTEN
>
> All four tasks are implemented on `frameless-window-chrome` (14 commits,
> 1844 tests, `bun run check` 0 errors). The checkboxes below are unticked
> because nobody went back to tick them, **not** because the work is pending.
>
> **The code blocks below are the PRE-REVIEW versions and three of them are
> known-defective.** Review found the defects after implementation and they
> were fixed in the branch, not here. Read the shipped files, not this plan:
>
> | Block | What is wrong with it |
> |---|---|
> | Task 3 Step 5, `WindowControls.svelte` | No `pointer-events` at all — reintroduces the modal deadlock (a dialog makes minimise/maximise/close dead on a window with no OS frame). Also no `.catch()` on any IPC call, and no `onResized` coalescing. |
> | Task 4 Step 5, the drag strip | Missing `pointer-events-auto`; same deadlock for window dragging. |
> | Task 1 Step 1, the `SHARED` allowlist | Replaced in fix round 1 — an allowlist exempts any key ADDED to the base later, which is the exact drift the guard exists to catch. Derive from the base minus a denylist. |
> | Task 3 Step 1, the `controlsInset` tests | Tautological: they restate the implementation's formula over its own constants and cannot fail. Use hand-written literals. |
>
> The spec is the design of record and has been corrected; this file is kept as
> the execution log.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the Windows and Linux desktop windows the same edge-to-edge, no-OS-title-bar chrome macOS already has, with app-drawn window controls.

**Architecture:** `decorations: false` in per-platform Tauri config files (each restating the whole window object, because the config merge replaces arrays); a four-valued `windowChrome()` in `platform.ts` replacing a boolean that never had a production caller; and a `WindowControls.svelte` rendered from the ROOT layout — above the loading and onboarding branches — reserving space for itself through a single CSS variable.

**Spec:** `docs/superpowers/specs/2026-08-02-frameless-windows-linux-chrome-design.md`. Read its "Config: per-platform files, restated in full", "Capabilities" and "Resize edges" sections before Task 1 — each records a fact that is counter-intuitive and was verified against vendored source.

**Tech Stack:** Tauri 2.11, SvelteKit 2 + Svelte 5 runes, TypeScript, Tailwind 4, vitest.

## Global Constraints

- **This is a Windows/Linux feature being built on macOS.** No agent can run the acceptance matrix. Every task's *automated* gate is `bun run check` (0 errors) plus `bun run test`; the platform behaviour is a human step, listed per task under "Human acceptance" and collected at the end. **Never mark a task complete by claiming platform behaviour you did not observe** — say what was verified and what was not.
- **macOS must be untouched.** `overlayChrome()` keeps answering exactly as it does today for all five of its existing test inputs. That test is the regression guard; it may not be weakened.
- **No native/Rust code in this project.** Snap Layouts was dropped (spec, "Snap Layouts: considered, costed, dropped"), which removed the `windows` crate and every window-procedure concern. If a task seems to need FFI, stop — it is out of scope.
- **`decorations: false` never goes in `tauri.conf.json`.** That file is the macOS window too, and turning decorations off there removes the traffic lights.
- **Capabilities: add exactly three permissions** — `core:window:allow-minimize`, `core:window:allow-toggle-maximize`, `core:window:allow-close`. Do **not** add `allow-is-maximized`, `allow-internal-toggle-maximize` (both already in `core:default`), `allow-start-resize-dragging` (resizing is supplied by Tauri), or a `remote` block (the SPA is a *local* origin — see the spec's Capabilities section).
- **Frontend formatting:** there is no prettier in `frontend/`. Never run a formatter there. Match surrounding style by hand.
- Comments explain **why**, not what — match the density and voice of the files being edited.

---

### Task 1: Windows window config, restated in full, with a drift guard

**Files:**
- Modify: `desktop/src-tauri/tauri.windows.conf.json`
- Create: `frontend/src/lib/shell/tauri-config.test.ts`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: the restated-window-object pattern and the drift-guard test that Task 4 extends for Linux.

**Why the restatement:** Tauri merges `tauri.<platform>.conf.json` over the base with **JSON Merge Patch (RFC 7396)**, which replaces arrays wholesale (`tauri-utils-2.9.2/src/config/parse.rs:185`). `app.windows` is an array, so a fragment naming only `decorations` replaces the entire window list and every other field reverts to its serde default — including `create: true` (Tauri then auto-creates a `main` window that `build_main_window` duplicates) and `visible: true`, `width: 800`, `height: 600`.

- [ ] **Step 1: Write the failing test**

Create `frontend/src/lib/shell/tauri-config.test.ts`:

```ts
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
```

- [ ] **Step 2: Run it and watch it fail**

Run: `cd frontend && bun run test src/lib/shell/tauri-config.test.ts`
Expected: FAIL — `tauri.windows.conf.json` has no `app.windows`, so `mainWindow` returns null.

- [ ] **Step 3: Restate the window object**

Replace `desktop/src-tauri/tauri.windows.conf.json` with:

```json
{
  "app": {
    "windows": [
      {
        "label": "main",
        "create": false,
        "title": "Valea",
        "width": 1280,
        "height": 860,
        "minWidth": 1080,
        "minHeight": 700,
        "center": true,
        "resizable": true,
        "fullscreen": false,
        "visible": false,
        "decorations": false,
        "shadow": true
      }
    ]
  },
  "bundle": {
    "targets": ["nsis"],
    "externalBin": ["binaries/valea-server", "binaries/valea-spawn"]
  }
}
```

⚠️ **Do not add a comment to this file explaining the duplication.** These configs are parsed as **strict JSON** — `tauri-build`'s default feature set is `["config-json"]` and Valea enables no others (`desktop/src-tauri/Cargo.toml:18`), so JSON5 is off and `serde_json` rejects `//`. A comment here does not warn anyone; it fails the build. The warning lives in `tauri-config.test.ts`'s header comment, which is the file a reader hits when the guard fails.

**And do not "clean up" the repeated keys.** Tauri's platform merge replaces the whole `app.windows` array, so anything omitted reverts to its serde default: `create` to `true`, `visible` to `true`, the size to 800×600. The failure that produces is worth knowing precisely — Tauri auto-creates the `main` window before the setup hook, and `build_main_window`'s own build is then **rejected for a duplicate label**, not run alongside it. In debug that error propagates out of setup; in release it is logged and you are left with a visible, default-sized 800×600 window that the app never finished wiring. `externalBin` above already follows this pattern and is the existing precedent. `tauri-config.test.ts` is the guard.

The three macOS keys are deliberately absent: they are accepted everywhere and effective only on macOS.

- [ ] **Step 4: Run the test to verify it passes**

Run: `cd frontend && bun run test src/lib/shell/tauri-config.test.ts`
Expected: PASS (5 tests)

- [ ] **Step 5: Add the capability permissions**

In `desktop/src-tauri/capabilities/default.json`, add three entries to `permissions`, after `"core:window:allow-start-dragging"`:

```json
		"core:window:allow-minimize",
		"core:window:allow-toggle-maximize",
		"core:window:allow-close",
```

(The file is tab-indented — match it.) Add **only** these three. `allow-is-maximized` and `allow-internal-toggle-maximize` are already granted by `core:default`, and no `remote` block is needed: `is_local_url` treats a URL relative to `frontendDist`/`devUrl` as local, which both loopback origins are.

- [ ] **Step 6: Full check**

Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors; all tests pass.

- [ ] **Step 7: Commit**

```bash
git add desktop/src-tauri/tauri.windows.conf.json desktop/src-tauri/capabilities/default.json frontend/src/lib/shell/tauri-config.test.ts
git commit -m "feat(desktop): make the Windows window frameless, with a config drift guard"
```

**Human acceptance (cannot be automated here):** a Windows build launches exactly ONE window, 1280×860, centred, no title bar, still hidden until the backend is up.

---

### Task 2: `windowChrome()` replaces the boolean

**Files:**
- Modify: `frontend/src/lib/shell/platform.ts`
- Modify: `frontend/src/lib/shell/platform.test.ts`
- Modify: `frontend/src/lib/components/shell/Sidebar.svelte`
- Modify: `frontend/src/routes/+layout.svelte`

**Interfaces:**
- Consumes: nothing.
- Produces: `export type WindowChrome = 'browser' | 'macos-overlay' | 'windows' | 'linux'` and `export function windowChrome(): WindowChrome`. `overlayChrome(): boolean` stays, re-expressed through it. Task 3 renders on `windowChrome()`.

**Note the existing state before editing:** `overlayChrome()` has **no production call site** — only `platform.ts` and its test. `Sidebar`'s 48px band and `+layout`'s 12px strip are both gated on plain `inDesktop()`, so they already render on Windows and Linux today, where the 48px band is dead space beside a real title bar. This task is where that becomes intentional rather than accidental.

- [ ] **Step 1: Write the failing tests**

Add to `frontend/src/lib/shell/platform.test.ts` (the file already defines `MAC_UA`, `WINDOWS_UA`, `LINUX_UA`), and add `windowChrome` to the existing import from `./platform`:

```ts
describe('windowChrome', () => {
  it('is browser outside the desktop app, whatever the UA', () => {
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(windowChrome()).toBe('browser');
  });

  it('names each desktop platform', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(windowChrome()).toBe('macos-overlay');
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(windowChrome()).toBe('windows');
    vi.stubGlobal('navigator', { userAgent: LINUX_UA });
    expect(windowChrome()).toBe('linux');
  });

  // SSR and prerender have no `navigator` at all; `inDesktop()` short-circuits
  // before it is touched, so this must not throw.
  it('is browser during SSR, with no navigator', () => {
    vi.stubGlobal('navigator', undefined);
    expect(windowChrome()).toBe('browser');
  });

  // An unrecognised desktop UA must not silently become 'windows' and start
  // drawing controls over a native title bar. Unknown falls back to the one
  // answer that draws nothing.
  it('falls back to browser for an unrecognised desktop UA', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: 'Mozilla/5.0 (Unknown)' });
    expect(windowChrome()).toBe('browser');
  });

  // The macOS regression guard: `overlayChrome` must keep answering exactly as
  // it did before this function existed.
  it('keeps overlayChrome in agreement', () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.stubGlobal('navigator', { userAgent: MAC_UA });
    expect(overlayChrome()).toBe(true);
    vi.stubGlobal('navigator', { userAgent: WINDOWS_UA });
    expect(overlayChrome()).toBe(false);
  });
});
```

- [ ] **Step 2: Run to verify they fail**

Run: `cd frontend && bun run test src/lib/shell/platform.test.ts`
Expected: FAIL — `windowChrome` is not exported.

- [ ] **Step 3: Implement**

In `frontend/src/lib/shell/platform.ts`, replace the `overlayChrome` export with:

```ts
/**
 * Which window chrome the shell is drawing itself into.
 *
 * Four answers, not two: `decorations: false` gives Windows and Linux their own
 * frameless chrome, so "is this the macOS overlay" stopped being enough.
 *
 *   'browser'       — a real browser tab. Draws no window furniture.
 *   'macos-overlay' — `titleBarStyle: "Overlay"`: the OS still draws the
 *                     traffic lights, the SPA draws under them.
 *   'windows'       — frameless. The SPA draws min/max/close itself.
 *   'linux'         — frameless, same, GNOME-inspired.
 *
 * An unrecognised desktop UA answers `'browser'` on purpose. It is the only
 * value that draws nothing, and drawing our own controls over a real title bar
 * is a worse failure than drawing none.
 */
export type WindowChrome = 'browser' | 'macos-overlay' | 'windows' | 'linux';

export function windowChrome(): WindowChrome {
  if (!inDesktop()) return 'browser';
  const ua = navigator.userAgent;
  if (ua.includes('Macintosh')) return 'macos-overlay';
  if (ua.includes('Windows')) return 'windows';
  if (ua.includes('Linux') || ua.includes('X11')) return 'linux';
  return 'browser';
}

/** True only where the OS draws the title bar and the SPA draws under it. */
export function overlayChrome(): boolean {
  return windowChrome() === 'macos-overlay';
}
```

Keep the existing file header comment, updating the sentence that claims the compensations "must therefore key on macOS overlay, NOT on `inDesktop()`" — it describes an intent the components never implemented. Say instead that the components DID key on `inDesktop()`, that this is what `windowChrome()` fixes, and that the 48px band was dead space on Windows until now.

- [ ] **Step 4: Run to verify they pass**

Run: `cd frontend && bun run test src/lib/shell/platform.test.ts`
Expected: PASS, including all five pre-existing `overlayChrome` cases unchanged.

- [ ] **Step 5: Move the two call sites**

In `frontend/src/lib/components/shell/Sidebar.svelte`, replace `const desktop = inDesktop();` with:

```ts
  // The brand band doubles as the traffic-light clearance on macOS and as a
  // drag surface everywhere the app owns its frame. `windowChrome()` rather
  // than `inDesktop()`: the two are the same set today, but the reason the
  // band exists is the chrome, not the runtime.
  const chrome = windowChrome();
```

and the template's `{#if desktop}` with `{#if chrome !== 'browser'}`. Update the import.

In `frontend/src/routes/+layout.svelte`, the same substitution for the 12px strip.

- [ ] **Step 6: Full check**

Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors; all pass. No visual change on any platform — this task is a rename with a wider return type.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/shell/platform.ts frontend/src/lib/shell/platform.test.ts frontend/src/lib/components/shell/Sidebar.svelte frontend/src/routes/+layout.svelte
git commit -m "refactor(shell): windowChrome() replaces the boolean overlayChrome had become"
```

---

### Task 3: `WindowControls` on Windows, and the clearance it reserves

**Files:**
- Create: `frontend/src/lib/components/shell/WindowControls.svelte`
- Create: `frontend/src/lib/components/shell/window-controls.ts`
- Create: `frontend/src/lib/components/shell/window-controls.test.ts`
- Modify: `frontend/src/routes/+layout.svelte`
- Modify: `frontend/src/routes/layout.css`
- Modify: `frontend/src/lib/components/panes/PaneHost.svelte`
- Modify: `frontend/src/lib/components/shell/index.ts`

**Interfaces:**
- Consumes: `windowChrome()` from Task 2.
- Produces: `WindowControls.svelte` (no props), the `--window-controls-inset` CSS variable, and `controlsLabel(maximized: boolean)` from `window-controls.ts`.

**Placement is load-bearing.** It renders in `+layout.svelte` ABOVE all three branches, not in `AppShell`: the root layout renders `Onboarding` when no workspace is open and a bare loading surface while bootstrapping, and `AppShell` only exists in the third branch. Controls that appear once a workspace opens leave a first-run user unable to close the window. `fixed` positioning also sidesteps `AppShell`'s content column, which is `relative` only when `NAV_TOGGLE_PARKED` is false — and it is currently `true`.

- [ ] **Step 1: Write the failing test**

Create `frontend/src/lib/components/shell/window-controls.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { CONTROL_METRICS, controlsInset, controlsLabel } from './window-controls';

// The pure half of the control cluster. There is no component render harness in
// this repo, so this is where the logic that can be checked lives.
describe('controlsLabel', () => {
  it('offers to maximise a restored window', () => {
    expect(controlsLabel(false)).toBe('Maximise');
  });

  it('offers to restore a maximised one', () => {
    expect(controlsLabel(true)).toBe('Restore');
  });
});

// THE test that earns its keep. The inset every route header reserves and the
// width the buttons actually occupy are two numbers that must agree, and
// nothing in the browser will complain when they stop agreeing — the window
// controls will simply sit on top of a route's own buttons. Deriving the inset
// from the same metrics the component lays itself out from is what keeps them
// in step; this asserts the derivation rather than a hand-copied total.
describe('controlsInset', () => {
  it('reserves exactly the cluster width on Windows: three buttons, no gaps', () => {
    const { button, gap, padding } = CONTROL_METRICS.windows;
    expect(controlsInset('windows')).toBe(`${button * 3 + gap * 2 + padding * 2}px`);
  });

  it('reserves the buttons plus gaps and padding on Linux', () => {
    const { button, gap, padding } = CONTROL_METRICS.linux;
    expect(controlsInset('linux')).toBe(`${button * 3 + gap * 2 + padding * 2}px`);
  });

  // The routes must pay nothing where the OS draws the controls, or every
  // header on macOS and in the browser gains padding for furniture that is not
  // there.
  it('reserves nothing where the app does not draw the controls', () => {
    expect(controlsInset('macos-overlay')).toBe('0px');
    expect(controlsInset('browser')).toBe('0px');
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd frontend && bun run test src/lib/components/shell/window-controls.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Implement the pure half**

Create `frontend/src/lib/components/shell/window-controls.ts`:

```ts
import type { WindowChrome } from '$lib/shell/platform';

/**
 * The maximise button's meaning, which flips with a state that changes without
 * any click of ours (Win+Up, a window manager, a double-click on the drag
 * region). The component reads that state from `onResized`, never from its own
 * handler.
 */
export function controlsLabel(maximized: boolean): string {
  return maximized ? 'Restore' : 'Maximise';
}

/**
 * The cluster's geometry, in one place because TWO things depend on it and
 * they fail silently when they disagree: the component lays the buttons out
 * from these numbers, and every route header reserves `controlsInset()` of
 * right padding so its own controls do not end up underneath them. A width
 * changed in the component and not in the inset is invisible until the window
 * controls are sitting on top of a route's buttons.
 *
 * Windows is the platform convention: 46×32 caption buttons, flush to the
 * corner, no gaps and no padding. Linux is GNOME-INSPIRED rather than matching
 * — Linux has no single convention — so it gets round 24px buttons with
 * ordinary spacing.
 */
export const CONTROL_METRICS = {
  windows: { button: 46, height: 32, gap: 0, padding: 0, round: false },
  linux: { button: 24, height: 24, gap: 8, padding: 8, round: true }
} as const;

/** How much right-hand room the route headers must leave for the cluster. */
export function controlsInset(chrome: WindowChrome): string {
  const m = chrome === 'windows' || chrome === 'linux' ? CONTROL_METRICS[chrome] : null;
  if (!m) return '0px';
  return `${m.button * 3 + m.gap * 2 + m.padding * 2}px`;
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd frontend && bun run test src/lib/components/shell/window-controls.test.ts`
Expected: PASS (2 tests)

- [ ] **Step 5: Build the component**

Create `frontend/src/lib/components/shell/WindowControls.svelte`:

```svelte
<script lang="ts">
  /**
   * Minimise / maximise / close, drawn by the app because `decorations: false`
   * took the OS ones away on Windows and Linux.
   *
   * PLATFORM CONVENTION BEATS OURS HERE, and this is the only place in Valea
   * where that is true. On Windows people know exactly where these buttons are,
   * what size they are, and that close goes red on hover; furniture that
   * ignores that reads as a web page pretending to be an app. The Linux branch
   * is GNOME-INSPIRED and says so — Linux has no single convention (GNOME, KDE,
   * XFCE and tiling WMs all differ, and GNOME users can reorder or remove these
   * buttons), so claiming to "match the platform" there would be a promise
   * nothing can keep.
   *
   * It renders from the ROOT layout, above the loading and onboarding branches,
   * because `AppShell` does not exist in either — and a first-run user who
   * cannot close the window is the worst version of this feature. `fixed` also
   * means it needs no positioned ancestor, which `AppShell` does not reliably
   * provide (its content column is `relative` only when the nav toggle is
   * un-parked).
   *
   * Resizing is NOT our problem: Tauri reinstalls edge resizing for undecorated
   * windows on both platforms (`tauri-runtime-wry/src/undecorated_resizing.rs`
   * — a child HWND on Windows, a 5px webview inset on GTK). That child window
   * is also why these buttons are inset from the very top edge rather than
   * flush to it: the top few pixels belong to the resize border.
   */
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import Minus from '@lucide/svelte/icons/minus';
  import Square from '@lucide/svelte/icons/square';
  import Copy from '@lucide/svelte/icons/copy';
  import X from '@lucide/svelte/icons/x';
  import { controlsLabel } from './window-controls';
  import type { WindowChrome } from '$lib/shell/platform';

  let { chrome }: { chrome: Extract<WindowChrome, 'windows' | 'linux'> } = $props();

  const win = getCurrentWindow();
  let maximized = $state(false);

  // Seeded once, then driven by the WINDOW, never by our own click: Win+Up, a
  // window manager, and a double-click on the drag region all maximise without
  // going through these buttons, and a flag toggled in the handler would be
  // wrong from the first one of those.
  $effect(() => {
    let alive = true;
    void win.isMaximized().then((v) => {
      if (alive) maximized = v;
    });
    const off = win.onResized(() => {
      void win.isMaximized().then((v) => {
        if (alive) maximized = v;
      });
    });
    return () => {
      alive = false;
      // `onResized` resolves to the unlisten function; dropping it leaks a
      // listener per remount.
      void off.then((unlisten) => unlisten());
    };
  });
</script>

<!-- `fixed`, above everything, and OUTSIDE the drag strip rather than under it:
     the strip is a sheet on top, so anything beneath it never receives the
     click. `top-[1px] right-[1px]` clears the resize child window. -->
<div
  class={[
    'fixed top-[1px] right-[1px] z-[60] flex',
    chrome === 'linux' ? 'gap-2 p-2' : ''
  ]}
>
  <button
    type="button"
    onclick={() => void win.minimize()}
    aria-label="Minimise"
    title="Minimise"
    class={[
      'text-ink-secondary flex items-center justify-center transition-colors',
      chrome === 'windows'
        ? 'hover:bg-paper-pill h-8 w-[46px]'
        : 'bg-paper-pill hover:bg-paper-chip-border size-6 rounded-full'
    ]}
  >
    <Minus class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>

  <button
    type="button"
    onclick={() => void win.toggleMaximize()}
    aria-label={controlsLabel(maximized)}
    title={controlsLabel(maximized)}
    class={[
      'text-ink-secondary flex items-center justify-center transition-colors',
      chrome === 'windows'
        ? 'hover:bg-paper-pill h-8 w-[46px]'
        : 'bg-paper-pill hover:bg-paper-chip-border size-6 rounded-full'
    ]}
  >
    {#if maximized}
      <Copy class="size-3" strokeWidth={1.5} aria-hidden="true" />
    {:else}
      <Square class="size-3" strokeWidth={1.5} aria-hidden="true" />
    {/if}
  </button>

  <!-- The one control that gets a colour, because it is the one with a
       consequence — and because a red close hover is the Windows convention
       users look for. -->
  <button
    type="button"
    onclick={() => void win.close()}
    aria-label="Close"
    title="Close"
    class={[
      'text-ink-secondary flex items-center justify-center transition-colors hover:text-white',
      chrome === 'windows'
        ? 'h-8 w-[46px] hover:bg-[#c42b1c]'
        : 'bg-paper-pill size-6 rounded-full hover:bg-[#c42b1c]'
    ]}
  >
    <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>
</div>
```

- [ ] **Step 6: Render it, and reserve its space**

In `frontend/src/routes/+layout.svelte`, import `WindowControls` and `windowChrome`, then render above the three branches:

```svelte
{#if chrome === 'windows' || chrome === 'linux'}
  <WindowControls {chrome} />
{/if}
```

In `frontend/src/routes/layout.css`, add the inset variable — `0px` everywhere by default so no other platform pays for it:

```css
/* How much room the app-drawn window controls need at the top right. 0 where
   the OS draws them (macOS, browser); the root layout sets the real value when
   it renders `WindowControls`. One variable, one owner — the alternative was a
   `gutter` prop threaded through every route, which `NavToggle`'s comment
   records as having been tried and reverted. */
:root {
  --window-controls-inset: 0px;
}
```

Setting the real value needs an `$effect`, not an inline style: `+layout.svelte` renders fragments (`{#if}` branches and `{@render children()}`), so there is no single root element to hang `style=` on, and the variable has to reach `:root` for `PaneHost` to see it. In `+layout.svelte`'s `<script>`:

```ts
  // The controls are `fixed`, so nothing reserves their space automatically.
  // ONE variable on the document root, set here because this is the only
  // component that knows whether the controls render at all. Cleared on
  // destroy so a hot reload cannot leave a stale inset behind.
  //
  // The width comes from `controlsInset`, which derives it from the same
  // metrics the component lays the buttons out from — a hand-copied total here
  // would drift the moment a button width changed, and nothing would complain.
  $effect(() => {
    const inset = controlsInset(chrome);
    if (inset === '0px') return;
    document.documentElement.style.setProperty('--window-controls-inset', inset);
    return () => document.documentElement.style.removeProperty('--window-controls-inset');
  });
```

**The inset has FOUR consumers, not one.** `PaneHost` renders a header only around SIDE panes; every route's primary draws its own top row, and a route with no side panes open has no `PaneHost` header at all. Whichever surface is currently rightmost is the one under the controls, so each of these gets the same `padding-right` treatment:

| Surface | File | When it is rightmost |
|---|---|---|
| Side-pane header | `panes/PaneHost.svelte` | only the LAST pane in the row |
| Chat session header | `agent/SessionHeader.svelte:93` | chat primary, no side panes |
| Knowledge primary header | `routes/knowledge/[...path]/+page.svelte:308` | knowledge primary, no side panes |
| Calendar header | `routes/calendar/+page.svelte:139` | always — calendar has no `PaneHost` |

The rule in each is the same shape. For `PaneHost`, find the header `<div>` (`border-paper-hairline flex shrink-0 items-center gap-1 border-b px-3 pt-3 pb-2`) and add:

```svelte
        style={i === keyed.length - 1
          ? 'padding-right: calc(0.75rem + var(--window-controls-inset, 0px))'
          : undefined}
```

For the other three, add to the existing header element (adjusting the base padding to match what that element already has — `px-4` → `1rem`, `px-7` → `1.75rem`):

```svelte
  style="padding-right: calc(1rem + var(--window-controls-inset, 0px))"
```

⚠️ **The `, 0px` fallback is required, not defensive.** A `calc()` referencing an undefined custom property is an *invalid declaration at computed-value time* — the browser drops the whole `padding-right`, taking the base padding with it. Without the fallback, any context where `layout.css` has not applied (a component test harness, a storybook-style page, SSR before hydration) silently loses the header's horizontal padding entirely.

⚠️ **Do not try to solve this by making the controls non-`fixed`.** They must be `fixed` to survive the loading and onboarding branches, which have no shared layout ancestor with the routes. Four small declarations reading one variable is the cost of that, and it is still one owner rather than a prop threaded through nine routes.

Export `WindowControls` from `frontend/src/lib/components/shell/index.ts` alongside the other shell components.

- [ ] **Step 7: Full check**

Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors; all pass; macOS and browser render identically to before (`--window-controls-inset` is `0px` and the component does not render).

- [ ] **Step 8: Commit**

```bash
git add frontend/src/lib/components/shell/WindowControls.svelte frontend/src/lib/components/shell/window-controls.ts frontend/src/lib/components/shell/window-controls.test.ts frontend/src/lib/components/shell/index.ts frontend/src/routes/+layout.svelte frontend/src/routes/layout.css frontend/src/lib/components/panes/PaneHost.svelte
git commit -m "feat(shell): app-drawn window controls for frameless Windows and Linux"
```

**Human acceptance:** controls present and working on the loading screen, in onboarding, and in the app; maximise icon correct after Win+Up; controls not overlapping the pane header at 1080px; the resize child window does not eat the buttons' top edge.

---

### Task 4: The drag strip, and Linux

**Files:**
- Modify: `frontend/src/routes/+layout.svelte`
- Create: `desktop/src-tauri/tauri.linux.conf.json`
- Modify: `frontend/src/lib/shell/tauri-config.test.ts`

**Interfaces:**
- Consumes: `windowChrome()` (Task 2), `WindowControls` (Task 3), the drift guard (Task 1).
- Produces: nothing downstream.

- [ ] **Step 1: Extend the drift guard to Linux**

In `frontend/src/lib/shell/tauri-config.test.ts`, add:

```ts
  it('linux restates every shared key with the base value', () => {
    const linux = mainWindow('tauri.linux.conf.json');
    expect(linux).not.toBeNull();
    for (const key of SHARED) expect([key, linux?.[key]]).toEqual([key, base?.[key]]);
  });

  it('linux is frameless and asks for no shadow', () => {
    const linux = mainWindow('tauri.linux.conf.json');
    expect(linux?.decorations).toBe(false);
    // Tauri documents `shadow` as unsupported on Linux, and CSS cannot stand
    // in: a webview's box-shadow is clipped to the native window bounds and
    // `border-radius` does not shape the GDK surface. Asking for it would be
    // a claim the platform ignores.
    expect(linux?.shadow).toBeUndefined();
  });
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd frontend && bun run test src/lib/shell/tauri-config.test.ts`
Expected: FAIL — `tauri.linux.conf.json` does not exist (the read throws).

- [ ] **Step 3: Create the Linux config**

Create `desktop/src-tauri/tauri.linux.conf.json`:

```json
{
  "app": {
    "windows": [
      {
        "label": "main",
        "create": false,
        "title": "Valea",
        "width": 1280,
        "height": 860,
        "minWidth": 1080,
        "minHeight": 700,
        "center": true,
        "resizable": true,
        "fullscreen": false,
        "visible": false,
        "decorations": false
      }
    ]
  }
}
```

Same rule as the Windows file: the repetition is required, because Tauri's platform merge replaces the whole `app.windows` array. No `shadow` — Linux ignores it.

- [ ] **Step 4: Run to verify it passes**

Run: `cd frontend && bun run test src/lib/shell/tauri-config.test.ts`
Expected: PASS (7 tests)

- [ ] **Step 5: Stop the drag strip before the controls — and DO NOT widen it**

In `frontend/src/routes/+layout.svelte`, the only change the strip needs is to end before the controls:

```svelte
{#if chrome !== 'browser'}
  <!-- The top edge is a drag surface. It must END before the window controls,
       not layer over them: this element is `fixed`, so it is a sheet ON TOP
       rather than an ancestor, and the buttons beneath it would never be in
       the click's composed path at all. (Tauri's own drag script already
       refuses to drag when a BUTTON is in that path — that protection simply
       does not apply to a sheet above them.) `pointer-events: none` would
       disable the drag along with the problem. -->
  <div
    data-tauri-drag-region
    class="fixed top-0 left-0 z-50 h-3"
    style="right: var(--window-controls-inset, 0px)"
    aria-hidden="true"
  ></div>
{/if}
```

⚠️ **The height stays 3 (12px) on every platform.** An earlier draft of this plan widened it to 32px on Windows/Linux "so the whole top edge is draggable", and that is a bug: the strip is a `fixed z-50` sheet, so every pixel it covers stops being clickable. `PaneHost`'s header buttons are `size-8` with `-my-1.5` inside a 44px band, so they begin around y=6 — a 32px sheet would swallow most of promote and close on every side pane. The calendar route's content starts 24px from the top and would lose its top-right actions the same way.

⚠️ **The old justification for 12px was wrong, and the real one is narrower.** That comment used to read *"inside every pane's own top padding, so it never sits over anything interactive"* — this branch measured it and disproved it. The strip DOES clip the top of `PaneHost`'s header buttons: 4px with a title span (28px of target left), 6px without one (26px left). The comment was corrected in `+layout.svelte`; this paragraph is corrected here.

The actual reason 12px is load-bearing: **26px still clears WCAG 2.2 SC 2.5.8's 24×24 minimum**, and the 14px icon sits at y≈24, nowhere near the strip — so the user's aim point is untouched. A 32px strip would take the whole button. Do not read "the old justification was false" as "the constraint was a mistake": widening it also contradicts the spec's "no title bar strip" decision, since an invisible 32px band that eats clicks is a title bar in everything but appearance.

Dragging is not short-changed by this: the sidebar's 48px brand band is the primary drag surface and already renders on every desktop OS, exactly as on macOS today.

- [ ] **Step 6: Full check**

Run: `cd frontend && bun run check && bun run test`
Expected: 0 errors; all pass. macOS keeps its 12px strip spanning the full width, since `--window-controls-inset` is `0px` there.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/routes/+layout.svelte desktop/src-tauri/tauri.linux.conf.json frontend/src/lib/shell/tauri-config.test.ts
git commit -m "feat(desktop): frameless Linux window, and a drag strip that clears the controls"
```

**Human acceptance:** dragging works from the top edge and the sidebar band on both platforms; double-click maximises; the controls are clickable across their whole height.

---

## Human acceptance matrix (not automatable from macOS)

Collected here because no agent can run it. Full detail in the spec's Testing section.

| | Windows 11 | Windows 10 | Linux |
|---|---|---|---|
| One window, 1280×860, no title bar, hidden until backend up | | | |
| Min / max / close work | | | |
| Controls present on the loading screen and in onboarding | | | |
| Drag from top edge and sidebar band; double-click maximises | | | |
| Resize from 4 edges + 4 corners (Tauri-supplied) | | | |
| **Onboarding's Create-workspace dialog open: controls still work, window still drags** | | | |
| Controls not eaten by the resize child window — **RESTORED, not maximised** | | | n/a |
| Maximised: window does not overflow the work area or cover the taskbar | | | n/a |
| Maximise icon correct after Win+Up / WM change | | | |
| Alt+Space, Aero Shake, drag-to-top | | | n/a |
| Controls clear of the pane header at 1080px | | | |
| High-DPI 150% / 200%, second monitor at another scale | | | |
| Keyboard focus order and accessible names | | | |
| Forced-colors / high-contrast | | | |

**Linux is not one platform:** GNOME Wayland, GNOME X11, one non-GNOME environment (KDE or XFCE), `GTK_CSD=0`, fractional scaling, and touch resize (a different code path from mouse).
