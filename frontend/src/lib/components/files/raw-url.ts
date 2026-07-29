import { controlToken } from '$lib/socket';

/**
 * Display-time URL for a file's raw bytes — the same
 * `/files/raw?mount_key=…&path=…` shape `resolveImageSrc`
 * (`$lib/editor/image-upload.ts`) already uses for editor images, and the
 * exact `(mount_key, mount-relative path)` addressing
 * `FilesController.serve/2` expects. Usually an ICM mount; a mail
 * attachment addresses the account's `mail-<account>` mount instead (see
 * `rawFileOpenUrl` and `mailAttachmentTarget`).
 *
 * Both values are encoded as WHOLE query params (not per segment): a `/`
 * inside `path` becomes `%2F`, so nothing in a filename — separators,
 * `&`, `?`, spaces — can leak out and restructure the query string.
 */
export function rawFileUrl(mountKey: string, path: string): string {
  return `/files/raw?mount_key=${encodeURIComponent(mountKey)}&path=${encodeURIComponent(path)}`;
}

/**
 * The same URL made ABSOLUTE and carrying a `ticket` — the form for a
 * request that will be made by something other than this page's own
 * `fetch`: a new browser tab, or the OS browser via `openExternal` (the
 * mail attachment chip). Neither can send `x-valea-token`, which is the
 * whole reason the ticket exists — see `FilesController`'s "Tickets"
 * moduledoc section, and `api.fileTicket` for where one comes from.
 *
 * ABSOLUTE because `openExternal` hands the string to a different process
 * entirely, where a root-relative path has nothing to resolve against.
 * `origin` is the caller's `window.location.origin`, passed in rather than
 * read here so this stays a pure function: in the desktop that origin IS
 * the backend's (the SPA is served from it), and in browser dev it is the
 * Vite origin, which proxies `/files/raw` onward — correct in both without
 * this module knowing which it is in.
 *
 * The ticket is encoded as a WHOLE query param for the same reason
 * `mount_key`/`path` are.
 */
export function rawFileOpenUrl(
  mountKey: string,
  path: string,
  ticket: string,
  origin: string
): string {
  const url = `${rawFileUrl(mountKey, path)}&ticket=${encodeURIComponent(ticket)}`;
  return new URL(url, origin).href;
}

/**
 * Auth headers for a `/files/raw` request that is NOT an `<img>` src.
 *
 * The route is only partly token-exempt: images serve credential-free
 * (an `<img>` tag cannot send headers — that is the whole reason the
 * exemption exists), every other format requires a credential — this
 * header, or the `ticket` `rawFileOpenUrl` uses where a header is
 * impossible — and a request without one gets the route's opaque 404. See
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
