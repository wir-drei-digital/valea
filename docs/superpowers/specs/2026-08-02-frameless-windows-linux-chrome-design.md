# Frameless Window Chrome for Windows and Linux — Design

**Date:** 2026-08-02
**Status:** Approved (design), **one decision reopened** — see "Snap Layouts vs
the 1080px minimum" before planning
**Supersedes:** `2026-07-19-windows-support-design.md` §E2, which decided
Windows "gets standard decorations"
**Reviewed:** self-pass and Codex pass, 2026-08-02. The review log at the foot
records what each corrected and the one finding that was rejected.

## Goal

Give Windows and Linux the same edge-to-edge window macOS has had since the
overlay title bar shipped: no OS title bar, the app drawing to the window's own
edge, and the window controls sitting in Valea's own chrome.

macOS gets this from three config keys — `titleBarStyle: "Overlay"`,
`hiddenTitle`, `trafficLightPosition`. They are valid `WindowConfig` properties
on every platform, and their *effect* is macOS-only: Tauri accepts them
everywhere and honours them nowhere else. So Windows and Linux come up with
ordinary native decorations today.

The only cross-platform route is `decorations: false`, and it is **not the same
trade**. macOS's overlay keeps the traffic lights; `decorations: false` removes
the whole frame — minimise, maximise, close, and on Windows the Snap Layouts
flyout. What it does *not* remove is resizing: Tauri reinstalls that itself on
both platforms (see Resize edges). So the work is the controls, the drag
surfaces, and — if it survives the decision below — Snap Layouts.

Ships end to end:

1. **`WindowControls`** — a per-platform control cluster (minimise / maximise /
   close), rendered wherever the app owns the frame, **including onboarding and
   the loading screen**.
2. **Drag surfaces** that survive losing the native frame.
3. **`platform.ts` gains a four-valued chrome answer**, replacing a boolean
   that never had a production caller.
4. **Snap Layouts on Windows** — *conditional on the reopened decision*.

Explicitly **not** in scope: changing anything about the macOS window; a custom
menu bar (Valea has no menu bar); tabbed or multi-window support.

## Decisions taken (Daniel, 2026-08-02)

**Controls match each platform, not Valea.** Windows gets square ~46×32px
buttons flush to the top-right with the red close hover; Linux gets round
GNOME-style buttons. The alternative — one quiet Valea-styled set — was more
consistent with the design system and was rejected for the reason the design
system exists to serve: on Windows people know exactly where those buttons are,
and furniture that ignores that reads as a web page pretending to be an app.

⚠️ **This decision is honest on Windows and aspirational on Linux.** Linux has
no single control convention: GNOME, KDE, XFCE, Cinnamon and tiling WMs differ,
and GNOME users can reorder or remove buttons entirely. "Match the platform"
cannot be satisfied there. The Linux branch is therefore **GNOME-inspired, and
should be described that way in the code** rather than claiming to match a
platform that has no single answer.

**No title bar strip.** The app draws to the window edge exactly as on macOS:
the nav's top band is the drag surface, and the controls float at the top-right
of the content area — the mirror of where the traffic lights sit. A
conventional ~32px band was rejected for costing 32px of height on every screen
plus a horizontal rule the layout does not have.

**Snap Layouts are re-implemented, not conceded** — *taken before the sizing
problem below was known, and now reopened.*

## Snap Layouts vs the 1080px minimum — REOPENED

`tauri.conf.json` sets `minWidth: 1080`. Windows honours a window's minimum
size when snapping, so a zone narrower than 1080px cannot be filled:

| Display | Half | Third | Quarter |
|---|---|---|---|
| 1366×768 | 683 ✗ | 455 ✗ | 341 ✗ |
| **1920×1080** | **960 ✗** | 640 ✗ | 480 ✗ |
| 2560×1440 | 1280 ✓ | 853 ✗ | 640 ✗ |
| 3440×1440 | 1720 ✓ | 1146 ✓ | 860 ✗ |
| 3840×2160 | 1920 ✓ | 1280 ✓ | 960 ✗ |

**On 1920×1080 — the most common Windows display — every zone fails.**
Implementing the flyout there produces a menu that opens and then does not
work, which is worse than the honest absence of one. Microsoft's own guidance
is that snap-friendly windows should work at ~500 effective pixels, and
recommends 330.

Three ways out, none free:

1. **Drop Snap Layouts.** Costs nothing already built; the frameless window
   still works and Win+arrow snapping is unaffected (it also respects the
   minimum, but the user is not being offered a menu that lies).
2. **Lower `minWidth` toward ~800.** Makes snapping real, and is a genuine
   responsive-design project: `PRIMARY_MIN` (380) + `PANE_MIN` (300) + the
   236px nav already wants 916px before a single side pane fits, so below
   ~950px the app is nav-plus-one-pane and the nav collapse — currently
   **parked** — would have to come back.
3. **Ship it anyway** and accept that it is a large-monitor feature.

This is a product decision, not a technical one, and it must be made before the
plan is written: option 2 is a different and much larger project than the one
this spec describes.

## Architecture

### The chrome question becomes four-valued

`overlayChrome(): boolean` answers "is the SPA drawing under a macOS overlay".
With two more ways to own a frame a boolean cannot carry it:

```ts
export type WindowChrome = 'browser' | 'macos-overlay' | 'windows' | 'linux';
export function windowChrome(): WindowChrome;
```

Four values: one for the browser and three desktop chromes.

⚠️ **`overlayChrome()` has no production call site today** — only
`platform.ts` and its test. Its doc comment describes a separation that the
components do not actually implement: `Sidebar`'s 48px band and `+layout`'s
12px strip are both gated on plain `inDesktop()`, so **they already render on
Windows and Linux**, where the 48px band is currently dead space beside a real
title bar. That is a small existing bug this project happens to fix, and the
spec must not describe `platform.ts` as protection that is already in place.

`overlayChrome()` is kept as `windowChrome() === 'macos-overlay'` so the macOS
path has a regression guard while the rest is built, and the two call sites
above move to `windowChrome()`.

Detection stays UA-based for the reasons `platform.ts` already argues: it
decides presentation only, must answer synchronously during render, and the
three webviews Valea ships in are distinguishable. `inDesktop()` is checked
first and short-circuits, so SSR and browser dev answer `'browser'` without
touching `navigator`.

### Config: per-platform files, restated in full

`decorations: false` goes in `tauri.windows.conf.json` and a new
`tauri.linux.conf.json`. It must **not** go in `tauri.conf.json`, which is the
macOS window too.

**The merge is RFC 7396 JSON Merge Patch, which replaces arrays wholesale**
(`tauri-utils-2.9.2/src/config/parse.rs:185`). `app.windows` is an array, so
the obvious fragment —

```json
{ "app": { "windows": [{ "label": "main", "decorations": false }] } }
```

— does not add a key. It **replaces the window list with a one-element list
carrying only that key**, and every other field falls back to its serde
default. Two of those are actively harmful:

- **`create` defaults to `true`** (base sets `false`). Tauri auto-creates every
  `create: true` window before the setup hook (`tauri-2.11.2/src/app.rs:2516`,
  `.filter(|w| w.create)`), and `build_main_window` then builds a second window
  with the same `main` label.
- **`visible` defaults to `true`** (base sets `false`). Lesser: `build_main_window`
  calls `show()` almost immediately, so this is a brief flash rather than a
  hang — but a flash of an 800×600 window, since `width`/`height` revert too,
  along with `minWidth`, `minHeight`, `center`, `title` and `resizable`.

**So each platform file restates the window object in full.** The existing
`tauri.windows.conf.json` already demonstrates the pattern without explaining
it: it lists both `externalBin` entries, not just the added one, because that
array is replaced too. The duplication is load-bearing and gets a comment in
each file, since the instinct on reading it is to delete the "redundant" keys.

⚠️ This makes the platform files a **drift hazard** — a new base key has to be
added in three places, and the failure is silent on the platform nobody
develops on. A test reading all three files and asserting the non-platform keys
agree is the mitigation.

### Capabilities

`capabilities/default.json` already carries `core:window:allow-start-dragging`.
It gains exactly three:

- `core:window:allow-minimize`
- `core:window:allow-toggle-maximize`
- `core:window:allow-close`

**Not** `allow-is-maximized` and **not** `allow-internal-toggle-maximize`: both
are already in `core:window`'s default permission set, which `core:default`
pulls in (`gen/schemas/acl-manifests.json`). The second matters — it is the
command Tauri's drag script invokes on a double click, so double-click-to-
maximise already works.

**No `remote` block is needed, and one must not be added.** It looks as though
it should be: `default.json` is the only capability without one, while
`updates`, `notifications`, `mail-keychain` and `external-links` all list both
loopback origins. But `remote` governs URLs that are *not* the app's own, and
`is_local_url` (`tauri-2.11.2/src/webview/mod.rs:1698`) treats any URL relative
to `frontendDist` or `devUrl` as **local** — which `http://localhost:4817` and
`http://localhost:4273` both are. `local` defaults to `true`, so `default.json`
already applies to the SPA, which is why dragging works today. The four `remote`
blocks elsewhere are belt-and-braces. Adding one here would widen `core:default`,
`dialog` and `shell` to remote origins for no benefit — the exact security
trade the caution in Tauri's own docs is about.

### `WindowControls.svelte`

⚠️ **It cannot live in `AppShell`.** The root layout renders `Onboarding`
directly when no workspace is open, and a bare loading surface while
bootstrapping; route children — and therefore `AppShell` — only render in the
third branch (`+layout.svelte`). A frameless window whose controls appear only
after a workspace opens is a window a first-run user cannot close.

So it renders in **`+layout.svelte`, above all three branches**, beside the
existing drag strip. That also settles the containing block: ⚠️ `AppShell`'s
content column is `relative` only when `NAV_TOGGLE_PARKED` is false, and it is
currently `true`, so there is no positioned ancestor there to anchor to. The
root layout's own `fixed` positioning has no such dependency.

Being `fixed` to the window's top-right rather than the content column's is
also simply more correct: the content column's right edge **is** the window's
right edge, and opening panes does not move it — `PaneHost` divides space
*inside* `<main>`.

**Clearance.** One rule, one owner: the controls are `fixed`, and the clearance
is a single padding rule applied under `'windows' | 'linux'` — never a prop
threaded through routes, which is the trap `NavToggle`'s comment records from
the other side.

⚠️ **The pane header is the one real collision**, and the padding rule does not
solve it: `PaneHost`'s header already carries promote and close at its own
top-right, which on a single-pane route is exactly where the window controls
land. Global column padding would shrink all content for the full window height
to fix one 45px band. The honest fix is a shell-owned CSS variable
(`--window-controls-inset`, `0px` off Windows/Linux) that `PaneHost`'s header
adds to its right padding — one declaration, one consumer, no prop.

### Actions and state

`getCurrentWindow()` from `@tauri-apps/api/window`: `.minimize()`,
`.toggleMaximize()`, `.close()`.

The maximise icon depends on `.isMaximized()`, which is async and changes
without a click (double-clicking the drag region, Win+Up, a window manager). So
`maximized` is `$state`, seeded from `.isMaximized()` on mount and updated from
`.onResized()` — never from the click handler.

**Every listener is unsubscribed on destroy.** `onResized` and `onScaleChanged`
both return an unlisten function; a component that drops them leaks a listener
per remount.

### Drag surfaces

- `Sidebar`'s 48px band — reused as-is; it already renders on every desktop OS.
- `+layout`'s fixed 12px top strip — kept, and widened to the control cluster's
  height on Windows/Linux, and it must **stop short of the controls
  horizontally**, not layer over them.

  The reason is worth stating precisely, because the obvious one is wrong.
  Tauri's drag script walks the composed path and refuses to drag when it finds
  a `BUTTON` (or link, input, `[tabindex]`, interactive `role`) without its own
  drag attribute, so a button *inside* a drag region is safe by construction
  (`tauri-2.11.2/src/window/scripts/drag.js`). What is not safe is this strip:
  it is `fixed … z-50`, a sheet *on top*, so the buttons are never in the
  composed path — the strip is the hit target and the top rows of every control
  would drag the window. Ending the strip before the controls is the fix;
  `pointer-events: none` would disable the drag with it.

Double-click on a drag region toggles maximise via the same script's
`internal_toggle_maximize` — no handler needed, and adding one would
double-fire.

### Resize edges — no work required

**Tauri reinstalls resizing for undecorated windows on both platforms**
(`tauri-runtime-wry-2.11.2/src/undecorated_resizing.rs`):

- **Windows** — a dedicated **child HWND** overlaying the border region with
  its own DPI-aware `WM_NCHITTEST` (`:277`).
- **Linux** — GTK button-press and touch handlers on the webview with a
  `BORDERLESS_RESIZE_INSET` of 5px, calling `begin_resize_drag` (`:503`).

So `startResizeDragging` and `ResizeDirection` — which do exist in
`@tauri-apps/api/window` — are not needed, nor is the permission, nor a
`ResizeEdges` component, which would duplicate or fight the existing handler.

Three consequences survive:

- ⚠️ **The Windows child HWND overlays the border region**, which the top few
  pixels of the control cluster sit in. The buttons must be inset far enough
  that their hit area is not eaten, or the top rows resize instead of clicking.
- ⚠️ **No resize cursor on Linux** — a known upstream FIXME: `begin_resize_drag`
  uses the default cursor. The edges work but do not advertise themselves.
  Cosmetic and deferrable.
- **`shadow` is unsupported on Linux**, and CSS cannot substitute: a webview's
  box-shadow is clipped to the native window bounds and `border-radius` does
  not shape the GDK surface. Linux gets square opaque windows unless someone
  later specifies transparency and native shaping. On Windows `shadow: true`
  gives rounded corners on Win11 plus a **1px white border** — hard white
  against Valea's warm paper, which wants looking at rather than assuming.

**Resizing stops while maximised** on both platforms, by design.

### Snap Layouts (Windows) — if it survives the decision above

The OS opens the flyout when the window reports `HTMAXBUTTON` from
`WM_NCHITTEST`. A frameless window reports `HTCLIENT` everywhere.

**Coexistence first.** Tauri already subclasses the frameless window *and*
overlays the resize child HWND. A new subclass must use a unique subclass ID,
forward everything it does not handle through `DefSubclassProc`, remove itself
and free its state at `WM_NCDESTROY`, and be tested for ordering against the
existing handler.

**Messages — five, not four:** `WM_NCHITTEST`, `WM_NCMOUSEMOVE`,
`WM_NCMOUSELEAVE`, `WM_NCLBUTTONDOWN`, `WM_NCLBUTTONUP`.

⚠️ **`WM_NCMOUSELEAVE` does not arrive on its own.** The handler must call
`TrackMouseEvent` with `TME_LEAVE | TME_NONCLIENT` on entering the button
region and re-arm after each leave, or hover sticks on permanently.

⚠️ **Coordinates are screen-space, not client-space.** `WM_NCHITTEST`'s `lParam`
carries *screen* coordinates while `getBoundingClientRect()` gives webview CSS
pixels. Scaling alone cannot reconcile them — the point must go through
`ScreenToClient`/`MapWindowPoints`, and `GET_X_LPARAM`/`GET_Y_LPARAM` must be
used because monitors above or left of the primary give negative values.

⚠️ **Store the rect in LOGICAL coordinates.** Storing physical pixels makes a
DPI change unrecoverable: knowing the new scale factor does not reveal the
original logical rect, so the hit target stays stale until the frontend happens
to report again. Store logical, scale at hit-test time, and react to Tauri's
`onScaleChanged` — `onResized` is not a substitute.

⚠️ **The rect channel must not be `onResized` alone.** DOM geometry moves for
reasons a window resize does not cover (CSS, zoom, font metrics, visibility),
and a live resize fires many async invokes whose replies can land out of order
and store an older rect. Observe the button itself with `ResizeObserver`,
coalesce, and carry a monotonic generation number that the Rust side uses to
drop stale writes. **Or avoid the channel entirely** — the cluster is a fixed
size pinned to the top-right, so Rust can derive the rect from `GetClientRect`
and the known button metrics, which removes an entire class of staleness. The
plan should prefer this unless the metrics turn out to be dynamic.

⚠️ **Hover has to travel Rust → web, and that channel is not designed yet.**
Once the OS owns the hit-test the webview stops receiving mouse events over the
button, so the visual hover state must be driven from the WndProc. Emitting or
evaluating webview code synchronously from a window procedure is unsafe; the
design is an async event with an explicit payload, a listener with cleanup, and
a state machine that lives outside the WndProc.

⚠️ **The click needs a real state machine**, not just "swallow down, toggle up":
press capture, pressed visual state, release outside the button, cancellation,
double-click, and destruction while captured. `DefWindowProc` normally supplies
all of this for non-client buttons; taking it over means supplying it.

## Testing

The rule this repo has learned twice — *pure logic is reliably correct; nearly
every real defect lives in the wiring* — is sharpest here, where the wiring is a
native window proc. Unit tests are thin by design; the manual matrix is the
gate.

**Unit (vitest):**
- `windowChrome()` for each UA, plus SSR and non-desktop → `'browser'`.
- `overlayChrome()` unchanged for all five inputs — the macOS regression guard.
- The config-drift guard across the three Tauri config files.
- Which icon for which maximised state, as a pure function in a `.ts` sibling
  (there is no component render harness in this repo).

**Manual acceptance:**

| | Windows 11 | Windows 10 | Linux | macOS (regression) |
|---|---|---|---|---|
| No OS title bar | ✓ | ✓ | ✓ | unchanged |
| Min / max / close | ✓ | ✓ | ✓ | traffic lights unchanged |
| **Controls present on the loading screen** | ✓ | ✓ | ✓ | ✓ |
| **Controls present in onboarding (no workspace)** | ✓ | ✓ | ✓ | ✓ |
| Drag by the nav's top band | ✓ | ✓ | ✓ | ✓ |
| Double-click drag region maximises | ✓ | ✓ | ✓ | ✓ |
| Resize from 4 edges + 4 corners | ✓ | ✓ | ✓ | ✓ |
| Controls not eaten by the resize child HWND | ✓ | ✓ | n/a | n/a |
| Maximise icon correct after Win+Up / WM change | ✓ | ✓ | ✓ | n/a |
| Alt+Space system menu, Aero Shake, drag-to-top | ✓ | ✓ | n/a | n/a |
| Controls clear of the pane header at 1080px | ✓ | ✓ | ✓ | ✓ |
| High-DPI 150% / 200%, and a second monitor at another scale | ✓ | ✓ | ✓ | n/a |
| Snap Layouts flyout *(if built)* | ✓ | n/a | n/a | n/a |
| Keyboard focus order, accessible names, `aria-pressed` state | ✓ | ✓ | ✓ | ✓ |
| Forced-colors / high-contrast mode | ✓ | ✓ | ✓ | ✓ |

**Linux is not one platform.** At minimum: GNOME Wayland, GNOME X11, one
non-GNOME environment (KDE or XFCE), `GTK_CSD=0`, and fractional scaling —
plus touch resize, which goes down a different code path from mouse.

## Risks

**The Snap Layouts subclass is the whole technical risk** — native Win32,
per-message, failing as a dead rect or a crash. It is cleanly separable:
everything else ships without it. Given the 1080px finding, the honest ordering
is to ship the rest first and decide about the flyout with the frameless window
already in hand.

**The config restatement is the slow-burn risk**: wrong at build time is loud
(two windows, or a duplicate-label crash); *stale* in six months is silent and
only visible on the platform nobody develops on. The CI guard is the mitigation.

**Linux breadth** is the third: not resizing (Tauri supplies it) but the
control convention, which does not exist, and the environment matrix.

## Build order

Each step leaves the app working everywhere, macOS untouched throughout.

1. **`tauri.windows.conf.json` restates the full window object** with
   `decorations: false`, `shadow: true`. Acceptance: a Windows build shows
   exactly one window, 1280×860, still hidden until the backend is up.
2. **`windowChrome()`** plus tests; `overlayChrome()` re-expressed through it;
   the two `inDesktop()` chrome call sites moved onto it. No visual change.
3. **`WindowControls`, Windows branch, in `+layout.svelte`** — above all three
   layout branches, `fixed` top-right, actions, maximised state, listener
   cleanup, and the `--window-controls-inset` variable consumed by `PaneHost`'s
   header. Windows is usable frameless here.
4. **Drag strip** — widened, ending before the controls; confirm the resize
   edges arrive and the child HWND does not eat the buttons.
5. **Linux** — `tauri.linux.conf.json` (restated, no `shadow`), the
   GNOME-inspired branch, and the environment matrix.
6. **Config drift guard.**
7. **Snap Layouts** — *only if the reopened decision keeps it*: coexistence,
   the five messages, `TrackMouseEvent`, screen→client mapping, logical rect
   via `GetClientRect` if possible, the async hover channel, the click state
   machine.

## Review log

**Self-pass** corrected four claims against installed source: the config merge
(RFC 7396, arrays replaced — had been left as "the plan must verify"), resize
edges being free on both platforms (had been the spec's second-largest risk and
was simply wrong), two of five permissions already granted by `core:default`,
and the drag-strip hazard's mechanism.

**Codex pass** found, and verification confirmed: `WindowControls` in
`AppShell` would leave onboarding and the loading screen with no controls;
`overlayChrome()` has no production call site so the introduction's framing was
wrong; `WM_NCMOUSELEAVE` needs `TrackMouseEvent`; the hit-test compares screen
against client coordinates, which scaling cannot fix; a stored *physical* rect
cannot be rescaled after a DPI change; the new subclass must coexist with
Tauri's own and its resize child HWND; the rect channel is stale and
reorderable; the hover and click paths were undesigned; `AppShell` offers no
positioned ancestor while the nav toggle is parked; opening panes does not move
the content column's right edge; "three-valued" listed four; "exactly four
messages" listed five; the macOS keys exist in the shared schema and are merely
macOS-*effective*; CSS cannot supply a Linux exterior shadow; Linux is not
GNOME; and the acceptance matrix was missing startup states, Windows 10,
`Alt+Space`, accessibility and listener cleanup. **It also produced the finding
that reopened a settled decision**: `minWidth: 1080` makes every snap zone fail
on a 1920×1080 display.

**One Codex finding was rejected.** It reported as Critical that the capability
changes "will not authorize Valea's actual SPA origins" because `default.json`
has no `remote` block while every other capability does. That inference from the
repo's pattern is reasonable and the conclusion is wrong: `is_local_url`
(`tauri-2.11.2/src/webview/mod.rs:1698`) treats any URL relative to
`frontendDist`/`devUrl` as local, `local` defaults to `true`, and `4817`/`4273`
are exactly those. `default.json` already applies — which is why
`allow-start-dragging` works today. Acting on the finding would have widened
`core:default`, `dialog` and `shell` to remote origins for nothing. The
reasoning is recorded under Capabilities so it is not "fixed" again later.
