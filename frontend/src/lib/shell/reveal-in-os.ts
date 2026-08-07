// Reveals a file in the OS file manager — Finder, Explorer, whatever the
// desktop has. Desktop ONLY: the backend runs on the same machine and could
// shell out, but that would add a process-exec surface for a convenience,
// and the desktop is where this is reached.
//
// One of the FOUR modules allowed to touch Tauri IPC (see keychain.ts's
// header comment — the grep-able boundary).
import { revealItemInDir } from '@tauri-apps/plugin-opener';
import { inDesktop } from '$lib/keychain';
import { windowChrome } from './platform';

/** Just enough of `MountSummary` to locate a mount — structurally typed so this stays a leaf module with no dependency on the store layer. */
type MountRoot = { mountKey: string; root: string };

/**
 * A node's absolute path: the mount's resolved `root` plus its ICM-relative
 * path. `null` when the mount is unknown, has no root, or `relPath` would
 * escape it (absolute, or carrying a `..` segment) — so a caller offers
 * nothing rather than aiming the file manager at a wrong, possibly
 * out-of-mount path.
 *
 * `opener:allow-reveal-item-in-dir` ships with no pre-configured scope of
 * its own, so this containment check is the ONLY thing standing between
 * `revealInOs` and revealing an arbitrary filesystem location — worth
 * doing properly even though every real caller today builds `relPath` from
 * a backend directory listing, where a literal `..` segment cannot occur.
 */
export function absPathFor(
  mounts: readonly MountRoot[],
  mountKey: string,
  relPath: string
): string | null {
  const root = mounts.find((m) => m.mountKey === mountKey)?.root;
  if (!root) return null;

  const trimmed = root.replace(/\/+$/, '');
  if (!relPath) return trimmed;

  // Reject anything that could walk the join outside the mount. Absolute
  // `relPath` would make the join ignore `trimmed` outright; a `..`
  // SEGMENT walks back up a directory. Testing split segments — not a
  // substring match — is what lets a real filename like `..notes.md` or
  // `foo..bar` through unrejected.
  if (relPath.startsWith('/')) return null;
  if (relPath.split('/').some((segment) => segment === '..')) return null;

  const joined = `${trimmed}/${relPath}`;

  // Verified, not merely intended: confirm the join actually landed inside
  // the mount rather than trusting the two checks above to have covered
  // every way out.
  return joined.startsWith(`${trimmed}/`) ? joined : null;
}

/**
 * What the menu item should say. Named for the app the user will actually
 * see, because "Reveal in Finder" on Windows reads as a bug. Linux has no
 * single file manager to name, so it gets the generic phrase.
 */
export function revealLabel(): string {
  switch (windowChrome()) {
    case 'macos-overlay':
      return 'Reveal in Finder';
    case 'windows':
      return 'Show in Explorer';
    default:
      return 'Show in file manager';
  }
}

export function canRevealInOs(): boolean {
  return inDesktop();
}

/** Best-effort — never throws. Same quiet posture as `openExternal`/`keychain`. */
export function revealInOs(absPath: string): void {
  if (!canRevealInOs() || !absPath) return;

  revealItemInDir(absPath).catch(() => {
    // Nothing actionable for the caller: the path is gone, or the platform
    // refused. Failing silently beats a dialog about a file manager.
  });
}
