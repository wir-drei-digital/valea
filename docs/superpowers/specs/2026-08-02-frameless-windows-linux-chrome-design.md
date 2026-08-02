# Frameless Window Chrome for Windows and Linux — Design

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan
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
both platforms (see Resize edges). So the work is the controls and the drag
surfaces, and it is a smaller project than it first looked.

Ships end to end:

1. **`WindowControls`** — a per-platform control cluster (minimise / maximise /
   close), rendered wherever the app owns the frame, **including onboarding and
   the loading screen**.
2. **Drag surfaces** that survive losing the native frame.
3. **`platform.ts` gains a four-valued chrome answer**, replacing a boolean
   that never had a production caller.

Explicitly **not** in scope: changing anything about the macOS window; a custom
menu bar (Valea has no menu bar); tabbed or multi-window support; and **Windows
Snap Layouts**, which was considered, costed, and dropped — see below.

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

**Snap Layouts are DROPPED.** Reversed on 2026-08-02, the same day it was
taken: the original decision was "re-implement, not concede", made on the
belief that the cost was Win32 complexity. The real blocker is sizing — see the
next section — and the reversal deletes the single largest and riskiest piece
of this project.

## Snap Layouts: considered, costed, dropped

`tauri.conf.json` sets `minWidth: 1080`. Windows honours a window's minimum
size when snapping, so a zone narrower than that cannot be filled.

⚠️ **In EFFECTIVE (logical) pixels, not physical ones.** Tauri's `minWidth` is
logical (`tauri-utils-2.9.2/src/config.rs:1955`) and tao scales it to physical
for `WM_GETMINMAXINFO` (`tao-0.35.3/.../windows/event_loop.rs:1843`), so a
3840px panel at 200% is a 1920-effective-pixel workspace and behaves like the
row below, not like a 4K row. The table is therefore indexed by **effective
width**:

| Effective width | ½ | ⅓ | ¼ | ⅔ | ¾ |
|---|---|---|---|---|---|
| 1366 | 683 ✗ | 455 ✗ | 341 ✗ | 911 ✗ | 1024 ✗ |
| **1920** | **960 ✗** | 640 ✗ | 480 ✗ | **1280 ✓** | **1440 ✓** |
| 2560 | 1280 ✓ | 853 ✗ | 640 ✗ | 1706 ✓ | 1920 ✓ |
| 3440 | 1720 ✓ | 1146 ✓ | 860 ✗ | 2293 ✓ | 2580 ✓ |

**At 1920 effective pixels every half-or-smaller zone fails, and only the wide
side of an asymmetric layout works.** Windows' flyout offers roughly six zones;
two of them would accept the window. A menu where most options silently refuse
is worse than no menu, and there is no API to hide the ones that will not work.

*(An earlier draft of this section said "every zone fails" and divided physical
resolutions directly. Both were wrong — asymmetric layouts have ⅔ and ¾ zones,
and physical ≠ effective. The conclusion survives the correction, but it is a
narrower claim than the one originally made.)*

Microsoft's guidance is that snap-friendly windows should work at ~500
effective pixels, and recommends 330.

Three ways out were costed. **Daniel took the first (2026-08-02):**

1. **Drop it.** ✅ Costs nothing already built. The frameless window is
   unaffected, and so is Win+arrow snapping — that hits the same minimum, but
   nothing offered the user a menu and then failed to honour it.
2. **Lower `minWidth` toward ~800.** Buys less than it looks: at 1920 effective
   pixels 800 enables halves, but thirds (640) and quarters (480) still fail,
   and Microsoft's ~500 target is far below anything this layout reaches. It
   would **not** require restoring the parked nav collapse, contrary to an
   earlier draft — `panesThatFit` already refuses a side pane below
   `236 + 380 + 300 = 916` (`pane-fit.ts`), so the app degrades to nav plus
   primary on its own, and a primary-only view needs only 616px. The real cost
   is that every route has to be honest at 800px wide, which nothing has been
   designed for.
3. **Ship it as a large-monitor feature.** Rejected: the OS decides when to
   show the flyout, so there is no way to offer the two zones that work and
   hide the four that do not.

**What dropping it removes** — and this is most of the project's risk: the
`windows` crate dependency, a `SetWindowSubclass` that had to coexist with
Tauri's own subclass and its resize child HWND, a five-message non-client
handler, `TrackMouseEvent` arming for `WM_NCMOUSELEAVE`, screen↔client
coordinate mapping, a DPI-safe logical-rect channel from the webview, an async
Rust→web hover path, and a full press/capture/release state machine. Every
Critical-severity architectural risk raised in review was in that list.

**If it is ever revisited**, the prerequisite is option 2, not the Win32 work:
the subclass is only worth writing against a window that can actually fill a
snap zone.

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
  `.filter(|w| w.create)`). `build_main_window`'s own build is then **rejected
  for a duplicate label** rather than producing a second window
  (`tauri-2.11.2/src/manager/window.rs:66`). In debug that error propagates out
  of setup; in release it is logged, leaving a live window the app never
  finished wiring.
- **`visible` defaults to `true`** (base sets `false`), and `width`/`height`
  fall to 800×600 along with `minWidth`, `minHeight`, `center`, `title` and
  `resizable`. Combined with the above, the user sees an immediately-visible
  800×600 window — not the brief flash an earlier draft described, because
  `build_main_window`'s `show()` never runs.

**So each platform file restates the window object in full.** The existing
`tauri.windows.conf.json` already demonstrates the pattern without explaining
it: it lists both `externalBin` entries, not just the added one, because that
array is replaced too.

⚠️ **The explanation cannot go in the JSON files.** `tauri-build`'s default
feature set is `["config-json"]` and Valea enables no others
(`desktop/src-tauri/Cargo.toml:18`), so JSON5 is off and `serde_json` rejects
comments — a warning comment there fails the build rather than preventing the
mistake. It belongs in the drift-guard test, which is what a reader reaches
when the guard trips.

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
to the app's base URL as **local**. `local` defaults to `true`, so
`default.json` already applies to the page the app actually loads — which is
why `allow-start-dragging` works today.

⚠️ **Precisely: exactly ONE of the two ports is local per build.** Tauri picks
the base URL at compile time — `devUrl` in dev, `frontendDist` otherwise
(`tauri-2.11.2/src/manager/mod.rs:348`) — and `make_relative` requires scheme,
host *and* port to match. So 4273 is local in a dev build and 4817 in a
release one, never both at once. That makes the four `remote` blocks elsewhere
**not** redundant: `build_main_window`'s navigation guard permits both ports in
either build, so they authorise the origin that is not the compile-time local
one. The conclusion for `default.json` is unchanged — the SPA's own origin is
always the local one — but "both ports are local, the other blocks are
belt-and-braces" was wrong, and is corrected here because it is the kind of
reasoning someone would reuse.

Adding a `remote` block here would widen `core:default`, `dialog` and `shell`
to remote origins for no benefit — the exact trade the caution in Tauri's docs
is about.

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

⚠️ **Four surfaces collide, not one.** `PaneHost` renders a header only around
SIDE panes, so a route with none open has no `PaneHost` header at all and its
own primary header is what sits under the controls. The rightmost surface is
whichever of these is showing:

| Surface | When |
|---|---|
| `PaneHost`'s side-pane header | last pane in the row only |
| `SessionHeader` (chat) | chat primary, no side panes |
| The Knowledge primary's header band | knowledge primary, no side panes |
| Calendar's `<header>` | always — calendar renders no `PaneHost` |

Global column padding would shrink all content for the full window height to
fix a 45px band. The fix is a shell-owned CSS variable
(`--window-controls-inset`, `0px` everywhere else) that each of those four adds
to its right padding — one owner, four short declarations, and no prop threaded
through routes.

The variable is set on `document.documentElement` from the root layout, not as
an inline style: `+layout.svelte` renders fragments, so there is no element to
carry it, and a variable on the `fixed` controls element would not inherit into
route content at all. Every `calc()` reading it needs a `, 0px` fallback — a
`calc()` against an undefined custom property is invalid at computed-value time
and drops the whole declaration, base padding included.

### Actions and state

`getCurrentWindow()` from `@tauri-apps/api/window`: `.minimize()`,
`.toggleMaximize()`, `.close()`.

The maximise icon depends on `.isMaximized()`, which is async and changes
without a click (double-clicking the drag region, Win+Up, a window manager). So
`maximized` is `$state`, seeded from `.isMaximized()` on mount and updated from
`.onResized()` — never from the click handler.

**Every listener is unsubscribed on destroy**, and this is an acceptance
criterion rather than a note — a remount test belongs in the matrix, not just
in the prose.

⚠️ `onResized` returns a **`Promise<UnlistenFn>`**, not an unlisten function
(`@tauri-apps/api/window.d.ts`). Teardown therefore has to handle destruction
*before the promise resolves*: keep the promise, and unlisten in the cleanup by
chaining off it. A component that stores `await`ed results in a local and is
destroyed mid-registration leaks the listener it never saw.

### Drag surfaces

- `Sidebar`'s 48px band — reused as-is; it already renders on every desktop OS.
- `+layout`'s fixed 12px top strip — kept **at 12px on every platform**, and
  changed only to **stop short of the controls horizontally**.

  ⚠️ An earlier draft widened it to the control cluster's height on
  Windows/Linux "so the whole top edge is draggable". That is a bug and it
  contradicts this design's own "no title bar strip" decision. The strip is a
  `fixed z-50` sheet, so every pixel it covers stops being clickable:
  `PaneHost`'s header buttons are `size-8` with `-my-1.5` and begin around y=6,
  so a 32px sheet swallows most of promote and close on every side pane, and
  the calendar route's top-right actions go the same way. An invisible 32px
  band that eats clicks is a title bar in everything but appearance. 12px is
  the figure the existing comment justifies — *inside every pane's own top
  padding, so it never sits over anything interactive* — and the sidebar's 48px
  brand band is the real drag surface, exactly as on macOS.

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

### Snap Layouts — not built

Dropped; see "Snap Layouts: considered, costed, dropped" above for why and for
what the removal takes with it. Nothing in the sections above depends on it:
the controls, the drag surfaces and `windowChrome()` are the whole project now,
and none of them touches Win32.

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
| Keyboard focus order, accessible names, `aria-pressed` state | ✓ | ✓ | ✓ | ✓ |
| Listener cleanup: remount the controls, no duplicate `onResized` handlers | ✓ | ✓ | ✓ | ✓ |
| Forced-colors / high-contrast mode | ✓ | ✓ | ✓ | ✓ |

**Linux is not one platform.** At minimum: GNOME Wayland, GNOME X11, one
non-GNOME environment (KDE or XFCE), `GTK_CSD=0`, and fractional scaling —
plus touch resize, which goes down a different code path from mouse.

## Risks

**With Snap Layouts dropped there is no native code in this project at all** —
no `windows` crate, no window procedure, no FFI. That removes every
Critical-severity risk the review raised, and it is worth stating plainly
because the project's shape changed: what is left is a config file, a UA
helper, a Svelte component and a CSS variable.

**The config restatement is now the largest risk**: wrong at build time is loud
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
4. **Drag strip** — kept at 12px on every platform and ended before the
   controls; confirm the resize edges arrive and that Tauri's resize child HWND
   does not eat the top of the buttons. *(This line said "widened" until
   2026-08-02 and contradicted the Drag surfaces section three pages up, which
   had already been corrected. Widening it is a bug — a taller `fixed z-50`
   sheet swallows clicks on `PaneHost`'s header buttons and calendar's
   top-right actions.)*
5. **Linux** — `tauri.linux.conf.json` (restated, no `shadow`), the
   GNOME-inspired branch, and the environment matrix.
6. **Config drift guard** — a test reading all three Tauri config files and
   asserting the restated window keys agree. Last because it needs all three
   to exist.

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

**Third pass (Codex, against the rewrite)** caught three things that would have
reached the implementation, and corrected this document's own arithmetic:

- **Comments cannot go in the Tauri config files.** This spec had asked for one
  in each; `tauri-build`'s default is strict JSON, so it would have failed the
  build rather than warned anyone.
- **The drag strip must not be widened.** The rewrite had it growing to the
  control height on Windows/Linux; as a `fixed z-50` sheet that swallows
  `PaneHost`'s header buttons (which start around y=6) and calendar's top-right
  actions — and it contradicted this spec's own "no title bar strip" decision.
- **Four surfaces need the inset, not one.** `PaneHost` headers only side
  panes; chat, knowledge and calendar each own their rightmost header.
- **"Every snap zone fails at 1920" was overstated** — asymmetric layouts have
  ⅔ and ¾ zones that clear 1080 — and the table divided *physical* resolutions
  against a *logical* minimum. Both corrected above. The decision stands on the
  narrower claim.
- Smaller: the partial-config failure is a duplicate-label error rather than
  two windows; `onResized` returns a `Promise<UnlistenFn>`; listener cleanup
  was described but never made an acceptance criterion; and the `remote`
  rejection reached the right answer by the wrong route — only one port is
  local per build, so the other capabilities' `remote` blocks are load-bearing
  rather than belt-and-braces.

**The Snap Layouts reversal** came out of an earlier finding and is the review's
biggest single effect: a decision taken in the morning on the belief that the
cost was Win32 complexity, reversed the same day once the sizing arithmetic was
done. It deleted the largest task, the only native code, and every
Critical-severity risk in one move. Recorded because the lesson generalises —
the expensive question was not "can we build it" but "will it work on the
machine most people have".

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
