# Frameless Window Chrome for Windows and Linux — Design

**Date:** 2026-08-02
**Status:** Approved (design), pending implementation plan
**Supersedes:** `2026-07-19-windows-support-design.md` §E2, which decided
Windows "gets standard decorations"

## Goal

Give Windows and Linux the same edge-to-edge window macOS has had since the
overlay title bar shipped: no OS title bar, the app drawing to the window's own
edge, and the window controls sitting in Valea's own chrome.

macOS gets this from three config keys — `titleBarStyle: "Overlay"`,
`hiddenTitle`, `trafficLightPosition` — and the whole of the frontend's part is
two drag regions ([Sidebar.svelte:47](../../../frontend/src/lib/components/shell/Sidebar.svelte),
[+layout.svelte:64](../../../frontend/src/routes/+layout.svelte)). **None of
those keys exist off macOS.** Tauri ignores them, which is why
[platform.ts](../../../frontend/src/lib/shell/platform.ts) exists and why
`overlayChrome()` is deliberately `inDesktop() && navigator.userAgent.includes('Macintosh')`
rather than `inDesktop()` — the current layout compensations must NOT run on
Windows, where they would leave a dead strip under a real title bar.

The only cross-platform route is `decorations: false`, and it is not the same
trade. macOS's overlay **keeps the traffic lights**; `decorations: false`
removes the entire frame — minimise, maximise, close, the resize borders, the
drop shadow, and on Windows the Snap Layouts flyout. Everything it removes, we
draw or re-implement. That is the whole of this project.

Ships end to end:

1. **`WindowControls`** — a per-platform control cluster (minimise / maximise /
   close), rendered only where the app owns the frame.
2. **Snap Layouts restored on Windows** via a `WM_NCHITTEST` subclass in Rust,
   so hovering our maximise button opens the OS flyout.
3. **Resize and drag surfaces** that survive losing the native frame, on both
   platforms.
4. **`platform.ts` grows a third answer** — the chrome question stops being a
   boolean.

Explicitly **not** in scope: changing anything about the macOS window; a
custom menu bar (Valea has no menu bar); tabbed or multi-window support; and
per-platform *typography* or control *metrics* beyond the control cluster
itself.

## Decisions taken (Daniel, 2026-08-02)

Three forks, all decided before this document was written.

**Controls match each platform, not Valea.** Windows gets square 46×32px
buttons flush to the top-right corner with the red close hover; Linux gets
round GNOME-style buttons. The alternative — one quiet Valea-styled set on both
— was more consistent with the design system and was rejected for the reason
the design system exists to serve: on Windows people know exactly where those
buttons are and what they look like, and furniture that ignores that reads as a
web page pretending to be an app. This is the one place in Valea where the host
platform's convention outranks ours.

**No title bar strip.** The app draws to the window edge exactly as it does on
macOS: the nav's top band is the drag surface, and the controls float at the
top-right of the content area — the mirror image of where the traffic lights
sit today. A conventional ~32px band was rejected for costing 32px of height on
every screen plus a horizontal rule the layout does not currently have.

**Snap Layouts are re-implemented, not conceded.** It is the one thing Windows
users notice missing within a minute, and its absence is most of why custom
title bars feel broken there. It is also roughly half the Windows work — see
the risk register.

## Architecture

### The chrome question is now three-valued

`overlayChrome(): boolean` answers "is the SPA drawing under a macOS overlay".
With two more ways to own a frame, a boolean cannot carry it. It becomes:

```ts
export type WindowChrome = 'browser' | 'macos-overlay' | 'windows' | 'linux';
export function windowChrome(): WindowChrome;
```

`overlayChrome()` stays, as `windowChrome() === 'macos-overlay'`, so no existing
call site changes and the macOS path cannot regress while this is built.

The detection stays UA-based, for the reasons
[platform.ts](../../../frontend/src/lib/shell/platform.ts) already argues at
length: it decides presentation only, it must answer synchronously during
render, and across the three webviews Valea ships in — WKWebView, WebView2,
WebKitGTK — the UA distinguishes them. `Windows` and `Linux`/`X11` in the UA
string are as reliable as `Macintosh` is today. A wrong answer costs padding.

**`inDesktop()` is checked first and short-circuits**, unchanged: SSR,
prerender and browser dev must all answer `'browser'` without touching
`navigator`.

### Config: per-platform files, never a shared key

`decorations: false` goes in `tauri.windows.conf.json` and a new
`tauri.linux.conf.json`. It must **not** go in `tauri.conf.json`: that file is
the macOS window too, and turning decorations off there would take the traffic
lights with them and break the one platform that currently works.

Tauri v2 merges `tauri.<platform>.conf.json` over the base automatically, and
the repo already relies on this — `tauri.windows.conf.json` carries the NSIS
target and the `valea-spawn` sidecar today. The Windows file gains:

```json
{ "app": { "windows": [{ "label": "main", "decorations": false, "shadow": true }] }}
```

⚠️ **Verify the merge is per-window-object, not per-array.** Tauri merges
config objects, and `app.windows` is an ARRAY. If the platform file's array
REPLACES the base array rather than merging by label, the Windows window would
silently lose `width`, `minWidth`, `center`, `visible: false` and the rest —
and `visible: false` is load-bearing (`build_main_window` shows the window only
after the backend is up). The implementation plan's first task is to prove this
one way or the other and, if it replaces, to restate the full window object in
each platform file with a comment saying why the duplication exists.

### Capabilities

`capabilities/default.json` already carries `core:window:allow-start-dragging`
(that is what makes `data-tauri-drag-region` work today). It gains:

- `core:window:allow-minimize`
- `core:window:allow-toggle-maximize`
- `core:window:allow-close`
- `core:window:allow-is-maximized`
- `core:window:allow-start-resize-dragging`

These are added to the existing `default` capability rather than a new file:
the capability files in this repo are split by FEATURE that might be revoked
independently (mail keychain, external links, updates), and window controls are
not that — a window that cannot close is not a degraded mode anyone wants.

### `WindowControls.svelte`

One component, three branches, rendered by `AppShell` at the top-right of the
content column and only when `windowChrome()` is `'windows'` or `'linux'`.

```svelte
<!-- absolute, top-right of the content column; z above the pane headers -->
{#if chrome === 'windows'}   … three 46×32 square buttons …
{:else if chrome === 'linux'} … three 24px round buttons, 12px gutter …
{/if}
```

**Why the content column and not the nav:** the nav is the fixed anchor and its
top band is already the drag surface; the controls belong at the window's
top-right, which is the content column's top-right. It also mirrors macOS
exactly — traffic lights at the nav's top-left, controls at the content
column's top-right — so the two platforms are the same layout reflected, not
two layouts.

**What it costs the routes:** the same thing the traffic lights cost the nav —
clearance. Every route's first row must not sit under the controls. This is the
trap [NavToggle.svelte](../../../frontend/src/lib/components/shell/NavToggle.svelte)
documents from the other side: the `gutter` props that once threaded a
clearance through nine routes were reverted because one control, one owner, one
physical place is the only version that stays correct. So the controls are
absolutely positioned, and the clearance is **one padding rule on the content
column**, applied only under `'windows' | 'linux'` — never a prop.

⚠️ The pane header band is the row most at risk: it already holds promote and
close buttons at ITS top-right, and on a single-pane route that is exactly where
the window controls land. The implementation must check this at 1080px (the
configured `minWidth`) with two panes open, and the honest fix if they collide
is to reserve the clearance in `PaneHost`'s header rather than to move the
window controls somewhere unconventional.

### Actions

`@tauri-apps/api/window`'s `getCurrentWindow()`:

- minimise → `.minimize()`
- maximise → `.toggleMaximize()`
- close → `.close()`

The maximise button's ICON depends on `.isMaximized()`, which is async and
changes without a click (double-clicking the drag region, Win+Up, the Snap
flyout, a window manager). So the component holds `maximized` in `$state`,
seeds it from `.isMaximized()` on mount, and updates from `.onResized()` —
**not** from the click handler, which would go wrong the moment anything else
maximised the window.

### Drag surfaces

`data-tauri-drag-region` works with `decorations: false` on every platform. The
two regions that exist today were sized for macOS's traffic lights:

- `Sidebar`'s 48px band — **reused as-is**. It is already a chromeless drag
  surface in the desktop app; it simply stops being macOS-only. The `{#if
  desktop}` branch becomes `{#if chrome !== 'browser'}`, which it effectively
  already is.
- `+layout`'s fixed 12px top strip — **kept, and widened to the control
  cluster's height** on Windows/Linux, so the whole top edge is draggable
  rather than a 12px sliver. It must be `pointer-events: none` over the control
  buttons themselves, or the topmost 12px of every button becomes a drag
  handle that swallows the click. Simplest correct form: the strip stops short
  of the controls rather than layering under them.

Double-click on a drag region toggles maximise natively on Windows and GTK — no
handler needed, and adding one would double-fire.

### Resize edges

This is where the two platforms genuinely differ and where the plan must
measure rather than assume.

**Windows:** `decorations: false` with `shadow: true` keeps the resize borders
and the drop shadow, because Tauri keeps `WS_THICKFRAME` and extends the frame
into the client area. Expected to need no frontend work — **verify**.

**Linux (GTK/WebKitGTK):** ⚠️ the least certain part of this design.
`decorations: false` under GTK client-side decorations is expected to lose the
resize edges, in which case the app must provide them: 4–6px edge zones calling
`getCurrentWindow().startResizeDragging(direction)` with the eight
`ResizeDirection` values, plus CSS `border-radius` and a shadow the compositor
will not draw for us.

The plan's Linux task therefore starts with a measurement — resize a frameless
window from each edge and each corner on GNOME/Wayland and on X11 — and
branches on the answer. If edge zones are needed they are a `ResizeEdges`
component sibling to `WindowControls`, gated the same way, and NOT a set of
handlers sprinkled through the layout.

### Snap Layouts (Windows)

The flyout is opened by the OS when the window reports, via `WM_NCHITTEST`,
that the cursor is over the caption's maximise button (`HTMAXBUTTON`). A
frameless window reports `HTCLIENT` everywhere, so the OS never offers it.

Restoring it needs a window subclass in Rust:

1. `windows` crate dependency, `#[cfg(windows)]` only, `Win32_UI_Shell` and
   `Win32_UI_WindowsAndMessaging` features.
2. In `build_main_window`, after the window exists, take `window.hwnd()` and
   `SetWindowSubclass` a proc.
3. The proc handles exactly four messages and forwards everything else to
   `DefSubclassProc`:
   - `WM_NCHITTEST` — if the point is inside the maximise button's rect, return
     `HTMAXBUTTON`; else fall through.
   - `WM_NCMOUSEMOVE` / `WM_NCMOUSELEAVE` — drive the button's hover state,
     because once the OS owns the hit-test the webview stops receiving mouse
     events over that rect and the button would never light up.
   - `WM_NCLBUTTONDOWN` over `HTMAXBUTTON` — swallow it (the OS would otherwise
     do nothing) and let `WM_NCLBUTTONUP` toggle maximise.

**The button's rect has to cross from the webview to Rust**, and it moves: the
window resizes, and the content column's right edge moves when panes open. The
cheapest correct channel is a `#[tauri::command]` the component calls on mount
and on every `onResized`, storing a `Mutex<RECT>` in app state that the proc
reads. Passing a fixed rect at build time would be wrong within one pane open.

⚠️ **DPI.** `WM_NCHITTEST` coordinates are physical pixels; the webview's are
logical. The command must take logical coordinates and multiply by the window's
current scale factor, re-read on `WM_DPICHANGED` — a hard-coded 1.0 works on
exactly the developer's monitor and fails on every high-DPI Windows laptop,
which is most of them.

## Testing

The rule this repo has learned twice over — *pure logic is reliably correct;
nearly every real defect lives in the wiring where no test can see it* — is
especially true here, where the defects live in a native window proc. So the
unit tests are deliberately thin and the manual matrix is the real gate.

**Unit (vitest):**
- `windowChrome()` against each UA, plus SSR (no `navigator`) and
  non-desktop → `'browser'`.
- `overlayChrome()` still answers exactly as it does today for all five inputs
  — the regression guard on the platform that currently works.

There is no component render harness in this repo, so `WindowControls` gets no
render test; its logic that is worth testing (which icon for which maximised
state) is a pure function in a `.ts` sibling, tested there.

**Manual acceptance, per platform, and none of it is optional:**

| | Windows 11 | Linux (GNOME) | macOS (regression) |
|---|---|---|---|
| No OS title bar | ✓ | ✓ | unchanged |
| Min / max / close | ✓ | ✓ | traffic lights unchanged |
| Drag by the nav's top band | ✓ | ✓ | ✓ |
| Double-click drag region maximises | ✓ | ✓ | ✓ |
| Resize from all 4 edges + 4 corners | ✓ | ✓ | ✓ |
| Snap Layouts flyout on maximise hover | ✓ | n/a | n/a |
| Win+arrow / keyboard snap still works | ✓ | ✓ | n/a |
| Maximise icon correct after Win+Up | ✓ | ✓ | n/a |
| Controls clear of the pane header at 1080px | ✓ | ✓ | ✓ |
| High-DPI: hit-test aligned at 150% / 200% | ✓ | ✓ | n/a |
| Second monitor at a different scale | ✓ | ✓ | n/a |

The high-DPI and second-monitor rows exist because they are where a
hand-written hit-test fails, and both are invisible on the machine this is
written on.

## Risks

**The Snap Layouts subclass is the whole risk.** It is native Win32, it runs
per message, and the failure modes are a window that does not respond to the
mouse over one rect or an app that crashes on a message it mishandled. It is
also cleanly separable: everything else in this design ships without it, and
`HTMAXBUTTON` can be added afterwards without changing a line of the frontend
except the rect-reporting command. If it fights back, ship the rest and take
the deferral — the decision to implement it was made when it looked like half
the Windows work, and that estimate is the thing most likely to be wrong.

**Linux resize is the second.** If GTK does not give edges for free the work
doubles for that platform, and Wayland and X11 may not agree. Wayland is the
one to test first, since it is the default on current GNOME.

**Losing `visible: false`** to a config-array merge would show the window
before the backend is up — a white flash and a window that cannot do anything
yet. Caught by the first task, which is why it is first.

## Build order

Each step leaves the app working on every platform, and macOS untouched
throughout.

1. **Config merge proof** — `decorations: false` on Windows only; confirm every
   other window key survives, especially `visible: false`. Nothing else.
2. **`windowChrome()`** plus its tests, with `overlayChrome()` re-expressed
   through it. No visual change anywhere.
3. **`WindowControls`, Windows branch** — buttons, actions, maximised state
   from `onResized`, content-column clearance. Windows is now usable frameless
   without Snap Layouts.
4. **Drag and resize on Windows** — widen the top strip, verify the edges come
   free with `shadow: true`.
5. **Linux** — `tauri.linux.conf.json`, the GNOME control branch, and the
   resize measurement plus `ResizeEdges` if it turns out to be needed.
6. **Snap Layouts** — the `windows` crate, the subclass, the rect command, DPI.
   Last, because it is the one step that can be abandoned without unwinding
   anything before it.
