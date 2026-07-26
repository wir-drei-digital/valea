import type { RecentSessionGroup } from '$lib/stores/recent-sessions.svelte';

/**
 * The mount key of the most recently used ICM — the group owning the newest
 * session across every group (`startedAt` is ISO-8601, so plain string
 * comparison orders correctly). Falls back to `fallback` (the caller's
 * first-enabled-mount default) when no session exists anywhere yet; a
 * session with no `startedAt` sorts oldest rather than being skipped.
 *
 * Drives Today's quick composer: "start a session in the ICM I last worked
 * in" without asking, mirroring how the chat route's own `?icm=`-less
 * default picks the first enabled mount.
 */
export function mostRecentMountKey(
  groups: ReadonlyArray<Pick<RecentSessionGroup, 'mountKey' | 'sessions'>>,
  fallback: string | null
): string | null {
  let bestKey: string | null = null;
  let bestAt = '';

  for (const group of groups) {
    for (const session of group.sessions) {
      const at = session.startedAt ?? '';
      if (bestKey === null || at > bestAt) {
        bestKey = group.mountKey;
        bestAt = at;
      }
    }
  }

  return bestKey ?? fallback;
}
