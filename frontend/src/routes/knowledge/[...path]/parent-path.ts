/**
 * Derives the parent directory path of a node's full `path`, given the two
 * path vocabularies `Valea.ICM.tree/0` node `path`s use (A2-T5b):
 * workspace-relative `"mounts/<name>/…"` for an embedded mount, or an
 * ABSOLUTE physical path (leading `"/"`) for an external one.
 *
 * Naively splitting on `"/"` and filtering out empty segments (this
 * route's previous inline approach) drops an absolute path's leading empty
 * segment along with any other one, which silently turns
 * `"/Users/dana/Notes.md"` into `"Users/dana/Notes.md"` — the derived
 * parent then comes out `"Users"`, missing the leading `/` every external
 * node's `path` actually carries, so it never matches a real node in
 * `flatNodes` and the caller falls back to the flat Knowledge root (wrong
 * list pane contents, and "New" from that pane targeting `""` instead of
 * the real external folder).
 */
export function parentPath(path: string): string {
  // An absolute path's split keeps a leading `""` element (`"/a/b".split('/')
  // === ['', 'a', 'b']`) — popping the last real segment and rejoining puts
  // the `/` straight back, so the leading slash survives untouched. A
  // relative path has no such sentinel, so empty segments are filtered
  // instead (guards against a stray double slash) — unaffected by this fix.
  const segments = path.startsWith('/') ? path.split('/') : path.split('/').filter(Boolean);
  segments.pop();
  return segments.join('/');
}
