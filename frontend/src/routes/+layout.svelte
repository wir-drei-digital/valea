<script lang="ts">
  import '@fontsource-variable/newsreader';
  import '@fontsource-variable/newsreader/wght-italic.css';
  import '@fontsource-variable/instrument-sans';
  import '@fontsource/ibm-plex-mono/400.css';
  import '@fontsource/ibm-plex-mono/500.css';
  import './layout.css';
  import { onMount } from 'svelte';
  import Onboarding from '$lib/components/onboarding/Onboarding.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { updatesStore } from '$lib/stores/updates.svelte';
  import { refreshSidebarProjectStores, wireIcmEvents } from '$lib/stores/icm.svelte';
  import SearchPalette from '$lib/components/palette/SearchPalette.svelte';
  import WindowControls from '$lib/components/shell/WindowControls.svelte';
  import { controlsInset } from '$lib/components/shell/window-controls';
  import { windowChrome } from '$lib/shell/platform';

  let { children } = $props();

  // Wherever the app owns its frame — the macOS overlay, and frameless
  // Windows and Linux — no native title bar offers a grab handle, so a thin
  // strip along the very top edge is always a drag region. This is what makes
  // the window draggable on every screen, onboarding included (the sidebar's
  // brand band is a second, larger drag surface once the shell renders).
  //
  // 12px tall, on every platform. That is exactly a pane header's own top
  // padding (`pt-3`), so the strip clears the header's 24px content row and
  // leaves all but the ~6px overhang of its `size-8 -my-1.5` buttons
  // clickable. It must not grow "so the whole top edge drags": the strip is a
  // sheet on top (see the element's comment), so a 32px one would swallow
  // most of promote and close on every side pane, and the calendar route's
  // top-right actions with them. The sidebar's 48px brand band is the large
  // drag surface, and it renders on every desktop OS.
  //
  // Keyed on `windowChrome()` rather than `inDesktop()` because the strip
  // answers to the chrome, not the runtime.
  const chrome = windowChrome();

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

  // Joins `workspace:events` once, through the single `wireIcmEvents` call:
  // `icm_changed` keeps the sidebar tree live (Task 18 acceptance
  // criterion), and the `onWorkspace` pass-through re-syncs `workspaceStore`
  // on a `workspace` push (open/close, e.g. from another window) so this
  // window drops back to onboarding or picks up the newly-open one.
  //
  // Wired from `onMount` (not a state-dependent `$effect`) so this runs
  // exactly once per layout mount. `wireIcmEvents` is idempotent against
  // repeat calls, but calling it every time `workspaceStore.state` re-enters
  // 'open' (e.g. a workspace reopen) would still hit its "already wired"
  // branch and log a spurious console.warn on completely normal operation —
  // that warn is meant to flag a genuine second call site, not this one.
  onMount(() => {
    // COLD-LOAD bootstrap: `get_workspace` (via `workspaceStore.refresh()`)
    // is the ONLY way this window learns the current workspace on initial
    // load — `WorkspaceEventsChannel.join/3` pushes nothing on join, so the
    // `onWorkspace` handler below only ever fires on a LIVE switch (a
    // `workspace_opened`/`workspace_closed` broadcast), never now. The
    // sidebar's ICM project stores therefore refresh HERE once the
    // bootstrap resolves open; the switch path refreshes them from
    // `wireIcmEvents`'s own `onWorkspace` handler instead — see
    // `refreshSidebarProjectStores`'s doc comment (icm.svelte.ts) for the
    // two-call-site pattern.
    void workspaceStore.refresh().then(() => {
      if (workspaceStore.state === 'open') refreshSidebarProjectStores();
    });
    wireIcmEvents(() => {
      void workspaceStore.refresh();
    });

    // Auto-update polling — a no-op everywhere except the packaged desktop
    // app (see `updatesSupported`), so browser dev and vitest never start
    // timers. Idempotent, and the root layout never unmounts, so no cleanup.
    updatesStore.start();
  });
</script>

{#if chrome !== 'browser'}
  <!-- The top edge is a drag surface. It must END before the window controls,
       not layer over them: this element is `fixed`, so it is a sheet ON TOP
       rather than an ancestor, and the buttons beneath it would never be in
       the click's composed path at all. (Tauri's own drag script already
       refuses to drag when a BUTTON is in that path — that protection simply
       does not apply to a sheet above them.) `pointer-events: none` would
       disable the drag along with the problem.

       On macOS nothing sets `--window-controls-inset` (the OS draws the
       traffic lights), so the `0px` fallback spans the full width as before.

       `pointer-events-auto` for the same reason `WindowControls` carries it:
       bits-ui's scroll lock sets `document.body.style.pointerEvents = "none"`
       while any modal is open, and `app.html` nests the whole app inside
       `<body>`, so this strip inherits it. Without this the window cannot be
       DRAGGED while a dialog is open — Tauri hit-tests the event target, and
       an element with `pointer-events: none` is never one. -->
  <div
    data-tauri-drag-region
    class="pointer-events-auto fixed top-0 left-0 z-50 h-3"
    style="right: var(--window-controls-inset, 0px)"
    aria-hidden="true"
  ></div>
{/if}

<!-- ABOVE the three branches on purpose: `AppShell` only exists in the third
     one, so controls rendered there would leave anyone on the loading surface
     or in onboarding with no way to close the window. -->
{#if chrome === 'windows' || chrome === 'linux'}
  <WindowControls {chrome} />
{/if}

{#if workspaceStore.state === 'loading'}
  <div class="flex min-h-screen items-center justify-center bg-paper-surface"></div>
{:else if workspaceStore.state === 'none'}
  <Onboarding />
{:else}
  {@render children()}
  <SearchPalette />
{/if}
