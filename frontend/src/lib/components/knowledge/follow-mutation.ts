/**
 * Where the app goes after an ICM entry is renamed or deleted — across EVERY
 * surface that can be showing it.
 *
 * Both dialogs used to decide this by comparing `page.url.pathname` against
 * `knowledgeHref(mountKey, path)`. That question only ever finds the route's
 * own primary file. Composable views put files in two more places that a
 * pathname comparison cannot see:
 *
 *   - the primary Files surface's other tabs (`?tabs=<a>|<b>|<c>`)
 *   - any Files pane beside it (`?pane=files:<mount>/<a>|<b>`)
 *
 * A file left behind in either of those is worse than a stale address bar. For
 * `.md` the tab may eventually notice through the page watcher; for a PDF, an
 * image or a CSV there is no recovery at all — `FileView` forwards
 * `onVanished` only to `MarkdownPageView` — so the tab sits there dead and the
 * URL keeps naming a file that no longer exists.
 *
 * Returns a `goto` target, or `null` when nothing on screen was showing the
 * entry — which is the common case (renaming a row you are not reading).
 *
 * A folder carries its descendants: renaming `planning/` moves
 * `planning/CONTEXT.md` with it, deleting it takes it away. That is the same
 * prefix rule both dialogs already applied to the pathname, applied to every
 * surface instead of one.
 */
import { resolveTabs, type TabState } from '$lib/panes/files-pane-state';
import { filesPrimaryHref, parseFilesPrimary } from '$lib/panes/files-url';
import { parsePanes, withPanes } from '$lib/panes/pane-route';

export type MutationTarget = {
  mountKey: string;
  path: string;
  /** Folders match their descendants too; leaves match only themselves. */
  isFolder: boolean;
};

/**
 * The mount and ICM-relative path a `/knowledge/<mount>/<rel...>` pathname
 * names, decoded segment by segment exactly as the route itself does. `null`
 * for any other route — a rename fired from a Files PANE on `/chat` must
 * rewrite that pane and leave the transcript's own URL alone.
 */
function decodeKnowledgePath(pathname: string): { mountKey: string; path: string } | null {
  if (!pathname.startsWith('/knowledge/')) return null;
  try {
    const raw = pathname.slice('/knowledge/'.length).split('/');
    const mountKey = raw[0] ? decodeURIComponent(raw[0]) : '';
    if (!mountKey) return null;
    return { mountKey, path: raw.slice(1).map(decodeURIComponent).join('/') };
  } catch {
    // A malformed escape means we cannot know what this route is showing;
    // leaving it alone is the only honest answer.
    return null;
  }
}

export function followMutation(
  url: URL,
  target: MutationTarget,
  /** The entry's new path, or `null` when it was deleted. */
  newPath: string | null
): string | null {
  const covers = (p: string): boolean =>
    p === target.path || (target.isFolder && p.startsWith(`${target.path}/`));
  // A descendant keeps its suffix under the renamed folder; a leaf's suffix is
  // the empty string, so one expression covers both.
  const moved = (p: string): string | null =>
    newPath === null ? null : `${newPath}${p.slice(target.path.length)}`;

  /**
   * A whole tab strip carried through the mutation.
   *
   * A RENAME maps the paths in place, so the strip keeps its length and the
   * cursor keeps its meaning. A DELETE shortens it, which renumbers every tab
   * after the one that went — so the active and compare tabs are followed by
   * FILE and the state rebuilt around where they landed, never by holding an
   * index across a list that changed under it. An active tab that was itself
   * deleted falls back to the first survivor rather than to whatever slid into
   * its slot.
   */
  const rewriteTabs = (tabs: TabState): TabState => {
    const follow = (p: string): string | null => (covers(p) ? moved(p) : p);
    const after = tabs.paths.map(follow).filter((p): p is string => p !== null);
    const landed = (index: number | null): number | null => {
      if (index === null) return null;
      const next = follow(tabs.paths[index]);
      const at = next === null ? -1 : after.indexOf(next);
      return at === -1 ? null : at;
    };
    return resolveTabs(after, landed(tabs.active) ?? 0, landed(tabs.compare));
  };

  let changed = false;

  // Every pane is rebuilt as a FRESH array, mutated in place nowhere — the
  // host stops re-deriving its row layout otherwise (`paneRowLayout`).
  const panes = parsePanes(url.searchParams).map((pane) => {
    if (pane.kind !== 'files' || pane.mountKey !== target.mountKey) return pane;
    if (!pane.paths.some(covers)) return pane;
    changed = true;
    return { ...pane, ...rewriteTabs(pane) };
  });

  let primaryHref: string | null = null;
  const primary = decodeKnowledgePath(url.pathname);
  if (primary && primary.mountKey === target.mountKey) {
    const tabs = parseFilesPrimary(primary.path, url.searchParams);
    if (tabs.paths.some(covers)) {
      changed = true;
      const after = rewriteTabs(tabs);
      primaryHref =
        after.paths.length === 0
          ? // Nothing left to read. Back to the index, on the mount the file
            // was in rather than whichever one happens to be first in config
            // order — landing in a different ICM than you were just in reads
            // as the app losing your place.
            `/knowledge?icm=${encodeURIComponent(target.mountKey)}`
          : filesPrimaryHref(target.mountKey, after);
    }
  }

  if (!changed) return null;

  // `url.pathname + url.search` when the primary is untouched: `withPanes`
  // replaces the pane params and leaves `?tabs=`, `?icm=` and the rest alone.
  const base = new URL(primaryHref ?? url.pathname + url.search, url.origin);
  return withPanes(base, panes);
}
