<script lang="ts">
  /**
   * Minimise / maximise / close, drawn by the app because `decorations: false`
   * took the OS ones away — stated in `tauri.windows.conf.json` and
   * `tauri.linux.conf.json` alike, so both those windows come up with no
   * native frame and no OS-drawn buttons at all. `windowChrome()` cannot see
   * those files: the pairing is a convention, and a platform routed here
   * whose config still said `decorations: true` would get this cluster drawn
   * beside a real title bar.
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
   * The one place we do NOT follow Windows: a `focus-visible` ring, which the
   * OS caption buttons have no equivalent of. These are real `<button>`s and so
   * are in the tab order whether or not we style them; a focusable control with
   * no visible focus is the worse break.
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
   * — a child HWND on Windows, a 5px webview inset on GTK). It is also not
   * something we can opt out of near these buttons; see the offset comment on
   * the cluster below.
   */
  import { getCurrentWindow } from '@tauri-apps/api/window';
  import Minus from '@lucide/svelte/icons/minus';
  import Square from '@lucide/svelte/icons/square';
  import Copy from '@lucide/svelte/icons/copy';
  import X from '@lucide/svelte/icons/x';
  import { CONTROL_METRICS, controlsLabel } from './window-controls';
  import type { WindowChrome } from '$lib/shell/platform';

  let { chrome }: { chrome: Extract<WindowChrome, 'windows' | 'linux'> } = $props();

  const win = getCurrentWindow();
  let maximized = $state(false);

  /**
   * Every dimension comes from `CONTROL_METRICS`, in inline styles rather than
   * Tailwind utilities, because `controlsInset` adds these same numbers up to
   * tell the route headers how much room to leave. Restating 46px as
   * `w-[46px]` here would put the layout and the reservation in two places
   * that no test could compare — and their disagreement is silent: the
   * controls simply end up on top of a route's own buttons.
   *
   * Two gaps between three buttons, one padding on each side: this element's
   * width is therefore exactly `button * 3 + gap * 2 + padding * 2`, which is
   * the string `controlsInset` hands the route headers.
   */
  const m = $derived(CONTROL_METRICS[chrome]);
  const cluster = $derived(`gap: ${m.gap}px; padding: ${m.padding}px`);
  const box = $derived(`width: ${m.button}px; height: ${m.height}px`);
  // Windows caption buttons are bare until hover; the round Linux ones sit on
  // a resting pill, so their hover has to be a step darker than that pill
  // rather than the pill itself.
  const shape = $derived(m.round ? 'bg-paper-pill rounded-full' : '');
  const hover = $derived(m.round ? 'hover:bg-paper-chip-border' : 'hover:bg-paper-pill');

  /**
   * The three window operations. Best-effort, and none of them has anything to
   * report on failure — a refused `close` leaves the window open, which the
   * user can already see. Wrapped here rather than called inline so the
   * `catch` cannot be forgotten on one of the three: an IPC error (a revoked
   * capability, a call landing while the webview tears down) would otherwise
   * surface only as an unhandled rejection. Same quiet posture as
   * `keychain.ts`, whose import pattern this component follows.
   */
  const minimize = (): void => void win.minimize().catch(() => {});
  const toggleMaximize = (): void => void win.toggleMaximize().catch(() => {});
  const close = (): void => void win.close().catch(() => {});

  // Seeded once, then driven by the WINDOW, never by our own click: Win+Up, a
  // window manager, and a double-click on the drag region all maximise without
  // going through these buttons, and a flag toggled in the handler would be
  // wrong from the first one of those.
  //
  // COALESCED, because `onResized` is not an occasional event: it fires on
  // every `WM_SIZE`, which on Windows is continuous for the whole of an edge
  // drag — and a frameless window is precisely the one whose edges get
  // dragged. Left alone, every frame of that drag starts its own IPC
  // round-trip to answer a question whose answer changes only on
  // maximise/restore. `syncing` drops the fires that land while one is already
  // in flight, and `again` guarantees exactly one more read after the last of
  // them, so the settled state is never the one that gets skipped. (Re-reading
  // the same value is otherwise free: assigning an unchanged primitive to
  // `$state` notifies nothing.)
  $effect(() => {
    let alive = true;
    let syncing = false;
    let again = false;

    const sync = (): void => {
      if (syncing) {
        again = true;
        return;
      }
      syncing = true;
      void win
        .isMaximized()
        // A rejection leaves the last known state, which is a better answer
        // than any value this could invent.
        .catch(() => maximized)
        .then((v) => {
          if (alive) maximized = v;
          syncing = false;
          if (alive && again) {
            again = false;
            sync();
          }
        });
    };

    sync();
    const off = win.onResized(sync);

    return () => {
      alive = false;
      // `onResized` resolves to the unlisten function; dropping it leaks a
      // listener per remount, and awaiting it here is what covers a destroy
      // that lands before the listener is even installed. The `catch` matters
      // as much: without it a rejected registration becomes an unhandled
      // rejection on every unmount.
      off.then((unlisten) => unlisten()).catch(() => {});
    };
  });
</script>

<!-- GEOMETRY. `z-[60]` sits above the drag strip's `z-50`. The strip now ends
     at `--window-controls-inset` rather than spanning the width, so the two
     meet only in the 1px this cluster is nudged in from the right edge — but
     the z-order stays, because the strip is a sheet ON TOP and a button
     beneath it would never be in the click's composed path at all. Whoever
     changes either number should not have to rediscover that.

     `top-[1px] right-[1px]` NUDGES the cluster off the exact corner; it does
     not clear the resize border, and nothing in CSS can. Read from
     `tauri-runtime-wry/src/undecorated_resizing.rs`: on Windows a child HWND
     covers the whole window with a cut-out starting at `SM_CYFRAME` (~4px,
     DPI-scaled) — but only while the window is RESTORED, because the parent's
     `WM_SIZE` handler collapses that child to 0×0 once it is maximised. GTK
     skips its own hit-test (`scale_factor × 5` px from each edge) on exactly
     the same condition. So the top few pixels are resize territory when
     restored on both platforms and neither when maximised: restored is the
     state to check for it. A bigger offset would buy that edge back at the
     cost of the flush corner Windows users aim at, which is the worse trade.

     POINTER EVENTS, and both halves are load-bearing.

     `pointer-events-auto` on the BUTTONS is what keeps them alive during a
     modal. bits-ui's scroll lock sets `document.body.style.pointerEvents =
     "none"` for as long as any dialog is open
     (`internal/body-scroll-lock.svelte.js`), and `app.html` puts the SvelteKit
     root inside `<body>`, so this cluster inherits it and nothing ever
     restores it. On a frameless window that leaves minimise, maximise and
     close all dead — including behind onboarding's `CreateWorkspaceDialog`,
     where a first-run user's only remaining exits are Esc, Alt+F4 or the
     taskbar. Invisible on macOS, where the OS draws the traffic lights.

     `pointer-events-none` on the CONTAINER stops it swallowing clicks in the
     space between the buttons. On Linux the box is 104×40 and only 72×24 of it
     is button — the 8px padding ring and the two 8px gaps are inert — so
     without this the cluster is a click target over a third of its own area.
     What that currently costs is small and worth stating honestly: the strip
     ends at `--window-controls-inset`, so the dead space sits over the route
     header's reserved padding rather than over the strip, and only the 1px the
     cluster is nudged in from the right edge is drag surface. It is here as
     hygiene and as insurance for whoever next changes the strip's width or the
     cluster's padding, not because it reclaims much today. Windows sets padding
     and gap to 0, so there is no dead space there at all. -->
<div class="pointer-events-none fixed top-[1px] right-[1px] z-[60] flex" style={cluster}>
  <button
    type="button"
    onclick={minimize}
    aria-label="Minimise"
    title="Minimise"
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 pointer-events-auto flex items-center justify-center transition-colors outline-none focus-visible:ring-2',
      shape,
      hover
    ]}
  >
    <Minus class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>

  <button
    type="button"
    onclick={toggleMaximize}
    aria-label={controlsLabel(maximized)}
    title={controlsLabel(maximized)}
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 pointer-events-auto flex items-center justify-center transition-colors outline-none focus-visible:ring-2',
      shape,
      hover
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
    onclick={close}
    aria-label="Close"
    title="Close"
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 pointer-events-auto flex items-center justify-center transition-colors outline-none hover:bg-[#c42b1c] hover:text-white focus-visible:ring-2',
      shape
    ]}
  >
    <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>
</div>
