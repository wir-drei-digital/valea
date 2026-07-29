import { controlToken } from '$lib/socket';

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

/**
 * Auth headers for a `/files/raw` request that is NOT an `<img>` src.
 *
 * The route is only partly token-exempt: images serve credential-free
 * (an `<img>` tag cannot send headers — that is the whole reason the
 * exemption exists), every other format requires the control token, and a
 * request without it gets the route's opaque 404. See
 * `ValeaWeb.FilesController`'s "split credential" moduledoc section.
 *
 * Same header and same source as `client.ts`'s `uploadImage` and the HTTP
 * RPC fallback (`controlToken()` — see `socket.ts`); this is only a named
 * place to put it so `PlainTextView` and `PdfView` cannot drift apart.
 * `ImageView` and the editor's inline image srcs must NOT use it: they are
 * bare `<img>` tags on the exempt half.
 */
export function rawFileHeaders(): Record<string, string> {
  return { 'x-valea-token': controlToken() };
}
