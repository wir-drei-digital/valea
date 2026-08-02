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
 * they fail silently when they disagree: `WindowControls.svelte` sizes each
 * button from these numbers, and every route header reserves `controlsInset()`
 * of right padding so its own controls do not end up underneath them. A width
 * changed in the component and not in the inset is invisible until the window
 * controls are sitting on top of a route's buttons — which is why the component
 * reads `button`/`height`/`round` from here rather than restating them as
 * Tailwind utilities that no test could compare against the inset.
 *
 * Windows is the platform convention: 46×32 caption buttons, flush to the
 * corner, no gaps and no padding. Linux is GNOME-INSPIRED rather than matching
 * — Linux has no single convention (GNOME, KDE, XFCE and tiling WMs all
 * differ, and GNOME users can reorder or remove these buttons) — so it gets
 * round 24px buttons with ordinary spacing instead of a promise nothing can
 * keep.
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
