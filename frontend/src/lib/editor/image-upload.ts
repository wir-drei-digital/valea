/**
 * Pure logic for the image extension (Task C7). Mirrors the backend's
 * allowlist/vocabulary rules exactly, but does no I/O of its own — every
 * function here is a straight data transform, unit-tested in
 * `image-upload.test.ts`. `PageEditor.svelte` is the only impure caller
 * (DOM events, `api.uploadImage`, editor mutation).
 *
 * On-disk truth: an image node's `src` attr holds the `rel_from_page` value
 * the upload endpoint returned (or an absolute physical path for a page
 * inside an external mount) — never the `/files/raw?...` URL. That URL is a
 * DISPLAY-time mapping only, applied by `resolveImageSrc` inside the
 * extension's `renderHTML` (see `PageEditor.svelte`), so the markdown a page
 * serializes to stays a portable relative (or absolute-external) reference
 * rather than a copy of this app's local file-serving endpoint.
 */

// Mirrors `ValeaWeb.FilesController`'s `@allowed_types` exactly (extension
// AND content-type, no SVG — scriptable) so a paste/drop that would be
// rejected server-side is never even attempted.
const ALLOWED_TYPES: Record<string, string> = {
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp'
};

function extOf(name: string): string {
  const idx = name.lastIndexOf('.');
  return idx === -1 ? '' : name.slice(idx).toLowerCase();
}

/** True when `file`'s extension AND content type both match one of the allowed image kinds. */
export function isAllowedImage(file: File): boolean {
  const expectedType = ALLOWED_TYPES[extOf(file.name)];
  return expectedType !== undefined && file.type === expectedType;
}

function dirnameOf(path: string): string {
  const idx = path.lastIndexOf('/');
  return idx === -1 ? '' : path.slice(0, idx);
}

/**
 * Lexically resolves `rel` (a `../`-relative reference, as stored in an
 * image node's `src`) against `pageDir`, the directory the referencing page
 * lives in. Pure segment math, no filesystem access — mirrors
 * `Valea.Paths.relative/2`'s inverse on the backend. `pageDir` may be
 * workspace-relative (embedded mount) or an absolute physical path (external
 * mount); the result stays in the same vocabulary (a leading `/` on
 * `pageDir` is preserved on the output).
 */
export function joinRelative(pageDir: string, rel: string): string {
  const isAbsolute = pageDir.startsWith('/');
  const segments = [...pageDir.split('/'), ...rel.split('/')].filter((seg) => seg.length > 0);

  const stack: string[] = [];
  for (const seg of segments) {
    if (seg === '.') continue;
    if (seg === '..') {
      stack.pop();
    } else {
      stack.push(seg);
    }
  }

  const joined = stack.join('/');
  return isAbsolute ? `/${joined}` : joined;
}

const EXTERNAL_SRC_RE = /^(?:https?:|data:)/i;

/**
 * Maps an image node's on-disk `src` (relative-from-page, or absolute for an
 * external-mount page) to a `/files/raw?path=...` URL for DISPLAY. `http(s):`
 * and `data:` sources (not produced by this app's own upload flow, but valid
 * hand-authored markdown) pass through unchanged — they're already directly
 * renderable and have nothing to resolve against the page's location.
 */
export function resolveImageSrc(src: string, pagePath: string): string {
  if (EXTERNAL_SRC_RE.test(src)) return src;

  const resolved = src.startsWith('/') ? src : joinRelative(dirnameOf(pagePath), src);
  return `/files/raw?path=${encodeURIComponent(resolved)}`;
}
