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
      // listener per remount. Awaiting the promise in the teardown is what
      // covers a destroy that happens before the listener is even installed.
      void off.then((unlisten) => unlisten());
    };
  });
</script>

<!-- `fixed`, above everything, and OUTSIDE the drag strip rather than under it:
     the strip is a sheet on top, so anything beneath it never receives the
     click. `z-[60]` beats the strip's `z-50`, which is what puts these buttons
     back on top of it in the 12px they overlap.

     `top-[1px] right-[1px]` NUDGES the cluster off the exact corner; it does
     not clear the resize border, and nothing in CSS can. Read from
     `tauri-runtime-wry/src/undecorated_resizing.rs`: on Windows the child HWND
     covers the whole window with a cut-out that starts at `SM_CYFRAME` (~4px,
     DPI-scaled), so the top few pixels are the resize strip whatever we do
     here — exactly as they are above the OS's own caption buttons in a real
     title bar. On GTK the webview's own button-press handler claims
     `scale_factor × 5` px from each edge, and skips that entirely while the
     window is maximised. A bigger offset would buy the top edge back at the
     cost of the flush corner Windows users aim at, which is the worse trade. -->
<div class="fixed top-[1px] right-[1px] z-[60] flex" style={cluster}>
  <button
    type="button"
    onclick={() => void win.minimize()}
    aria-label="Minimise"
    title="Minimise"
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 flex items-center justify-center transition-colors outline-none focus-visible:ring-2',
      shape,
      hover
    ]}
  >
    <Minus class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>

  <button
    type="button"
    onclick={() => void win.toggleMaximize()}
    aria-label={controlsLabel(maximized)}
    title={controlsLabel(maximized)}
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 flex items-center justify-center transition-colors outline-none focus-visible:ring-2',
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
    onclick={() => void win.close()}
    aria-label="Close"
    title="Close"
    style={box}
    class={[
      'text-ink-secondary focus-visible:ring-ring/50 flex items-center justify-center transition-colors outline-none hover:bg-[#c42b1c] hover:text-white focus-visible:ring-2',
      shape
    ]}
  >
    <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
  </button>
</div>
