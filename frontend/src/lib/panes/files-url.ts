/**
 * The PRIMARY Files surface's address — the other half of `pane-route.ts`'s
 * `files:` wire form.
 *
 * A Files PANE carries its whole content in one `?pane=` value. The primary
 * cannot: it is a SvelteKit route, so the file being read has to be the
 * pathname (`/knowledge/<mount>/<rel...>`) or a deep link, a promotion, a
 * rename-follow and every breadcrumb above it would stop naming what is on
 * screen. So the split is:
 *
 *   pathname   the ACTIVE tab
 *   ?tabs=     the whole strip in order, `|`-joined and per-segment encoded
 *   ?compare=  the index of the tab showing beside the active one
 *
 * `?tabs=` lists the active tab too, rather than only the others, so switching
 * tabs is a plain navigation that leaves the strip byte-identical — the param
 * is the strip, and the pathname is the cursor into it. This replaces the
 * two-file `?split=<path>` form, which could only ever address the second of
 * two splits and has no meaning once there are six tabs.
 *
 * The two can disagree only if someone writes the URL by hand. The pathname
 * wins, because it is the route: a file the strip does not list is prepended
 * as the first tab rather than dropped, so the URL always renders the file it
 * names.
 */
import { encodePath, knowledgeHref } from '$lib/shell/nav';
import { resolveTabs, type TabState } from './files-pane-state';

const TAB_SEP = '|';

/** What the primary Files surface has open, from its pathname and query. */
export function parseFilesPrimary(
  /** The route's own ICM-relative path — `''` for a folder or the mount root. */
  path: string,
  searchParams: URLSearchParams
): TabState {
  const raw = searchParams.get('tabs');
  // A folder route has no open file, so it has no strip either: the tabs of
  // the file you were reading do not survive navigating to a folder, the same
  // way they do not survive a Files pane being pointed at another mount.
  if (path === '') return resolveTabs([], 0, null);

  const listed = raw ? raw.split(TAB_SEP).map(decodeSegmentPath) : [];
  const paths = listed.includes(path) ? listed : [path, ...listed];
  const compareRaw = searchParams.get('compare');
  const compare = compareRaw !== null && /^\d+$/.test(compareRaw) ? Number(compareRaw) : null;
  return resolveTabs(paths, paths.indexOf(path), compare);
}

/**
 * `URLSearchParams` has already percent-decoded the value as a whole, so what
 * is left is a `/`-joined path whose segments were encoded by `encodePath`. A
 * literal `%2F` inside a name survives that round trip as `%252F` and decodes
 * back here rather than being mistaken for a separator.
 */
function decodeSegmentPath(raw: string): string {
  try {
    return raw.split('/').map(decodeURIComponent).join('/');
  } catch {
    // An impossible escape cannot name a file; leaving it verbatim keeps it a
    // path that simply matches nothing, which the tree renders as an unopened
    // tab rather than a crash.
    return raw;
  }
}

/** Where the primary Files surface lives, given what it has open. */
export function filesPrimaryHref(mountKey: string, tabs: TabState): string {
  if (tabs.paths.length === 0) {
    // Nothing open — the mount root, which is a folder route: the tree with an
    // empty content area. Bouncing to the index instead would throw away where
    // the user was browsing.
    return `/knowledge/${encodeURIComponent(mountKey)}`;
  }
  // TWO encoding layers, and both are load-bearing. `encodePath` escapes a
  // literal `|` in a filename to `%7C` so the separator stays unambiguous;
  // `URLSearchParams` then escapes THAT `%` in turn, so reading the param back
  // undoes exactly one layer and hands `parseFilesPrimary` a string whose
  // remaining `%7C` is still a filename and whose bare `|` is still a
  // separator. Writing the joined list into the query by hand loses the first
  // layer to the query decoder and splits `a|b.md` into two tabs — which is
  // the same one-layer confusion `?pane=` avoids by going through
  // `withPanes`.
  const params = new URLSearchParams();
  // One tab needs no strip: `/knowledge/<mount>/<file>` on its own is exactly
  // that, which keeps the common URL as short as it has always been.
  if (tabs.paths.length > 1) params.set('tabs', tabs.paths.map(encodePath).join(TAB_SEP));
  if (tabs.compare !== null) params.set('compare', String(tabs.compare));
  const search = params.toString();
  return knowledgeHref(mountKey, tabs.paths[tabs.active]) + (search ? `?${search}` : '');
}
