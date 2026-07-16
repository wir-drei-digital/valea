/**
 * Derives the parent directory path of a node's full `path`. Every mounted
 * ICM is by-reference (task 4.2's re-key), and `Valea.ICM.tree_for/1` node
 * `path`s are always relative to that ICM's OWN root — never workspace-relative,
 * never absolute, never prefixed with the mount key — so there is only one
 * path vocabulary to handle here.
 */
export function parentPath(path: string): string {
  const segments = path.split('/').filter(Boolean);
  segments.pop();
  return segments.join('/');
}
