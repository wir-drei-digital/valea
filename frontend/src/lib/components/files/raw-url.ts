/**
 * Display-time URL for a file's raw bytes — the same
 * `/files/raw?mount_key=…&path=…` shape `resolveImageSrc`
 * (`$lib/editor/image-upload.ts`) already uses for editor images, and the
 * exact `(mount_key, ICM-relative path)` addressing
 * `FilesController.serve/2` expects.
 *
 * Both values are encoded as WHOLE query params (not per segment): a `/`
 * inside `path` becomes `%2F`, so nothing in a filename — separators,
 * `&`, `?`, spaces — can leak out and restructure the query string.
 */
export function rawFileUrl(mountKey: string, path: string): string {
  return `/files/raw?mount_key=${encodeURIComponent(mountKey)}&path=${encodeURIComponent(path)}`;
}
