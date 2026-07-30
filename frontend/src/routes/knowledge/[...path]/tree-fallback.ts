import type { EnsurePathResult } from '$lib/stores/icm.svelte';

/**
 * Which fallback the route's main pane shows for a path that has no rendered
 * node (issue #2 — a failed tree fetch must never read as a deleted page):
 *
 * - `'missing'` — ONLY on a definitive `ensurePathLoaded` miss (every listing
 *   on the walk succeeded and the node genuinely isn't there). This is the
 *   one state allowed to say "doesn't exist anymore".
 * - `'unavailable'` — some fetch failed: the ensure walk itself
 *   (`'unavailable'`), the mount list (`listError`, which also used to leave
 *   the skeleton up forever since `loaded` never flips), or this mount's
 *   root listing (`mountError`). Rendered as "couldn't load" + retry.
 * - `'loading'` — nothing failed, no definitive answer yet (or the node was
 *   found and no fallback will render at all): keep the skeleton.
 *
 * A definitive ensure answer wins over store-level errors in BOTH
 * directions: a `'missing'` walk proved the parent listing readable no
 * matter what `list_icms` said, and a `'found'` node renders normally, so
 * its fallback stays inert.
 */
export function treeFallback(args: {
  /** The settled ensure outcome for the CURRENT (mount, path), `null` until it settles. */
  ensureStatus: EnsurePathResult['status'] | null;
  listError: string | null;
  mountError: string | undefined;
}): 'loading' | 'missing' | 'unavailable' {
  if (args.ensureStatus === 'unavailable') return 'unavailable';
  if (args.ensureStatus === 'missing') return 'missing';
  if (args.ensureStatus === 'found') return 'loading';
  if (args.listError || args.mountError) return 'unavailable';
  return 'loading';
}
