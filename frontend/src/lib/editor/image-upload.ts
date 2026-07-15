/**
 * Pure logic for the image extension (Task C7). Mirrors the backend's
 * allowlist/vocabulary rules exactly, but does no I/O of its own — every
 * function here is a straight data transform, unit-tested in
 * `image-upload.test.ts`. `PageEditor.svelte` is the only impure caller
 * (DOM events, `api.uploadImage`, editor mutation).
 *
 * On-disk truth: an image node's `src` attr holds the `relFromPage` value
 * the upload endpoint returned — an ICM-relative reference, regardless of
 * whether the mount is embedded or external (Phase 4's `(mount_key,
 * ICM-relative path)` re-key collapsed that distinction; mount identity now
 * rides `mountKey`, a separate value, never a leading `/` on the path
 * itself) — never the `/files/raw?...` URL. That URL is a DISPLAY-time
 * mapping only, applied by `resolveImageSrc` inside the extension's
 * `renderHTML` (see `PageEditor.svelte`), so the markdown a page serializes
 * to stays a portable relative reference rather than a copy of this app's
 * local file-serving endpoint.
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

/**
 * Filters a batch of candidate files (a paste's clipboard files, or a drop's
 * `DataTransfer.files`) down to the ones `isAllowedImage` accepts, preserving
 * order. Used by both `handlePaste` and `handleDrop` in `PageEditor.svelte`
 * so every allowed image in a multi-file paste/drop is uploaded, not just
 * the first — a disallowed file anywhere in the batch (wrong type, SVG,
 * plain text) never blocks the allowed siblings around it. Pure: does not
 * touch the DOM `DataTransferItem`/`ClipboardEvent` types, so callers do
 * their own item-to-File extraction (e.g. filtering clipboard items to
 * `kind === 'file'` and calling `getAsFile()`) before calling this.
 */
export function allowedImageFiles(files: File[]): File[] {
  return files.filter(isAllowedImage);
}

function dirnameOf(path: string): string {
  const idx = path.lastIndexOf('/');
  return idx === -1 ? '' : path.slice(0, idx);
}

/**
 * Lexically resolves `rel` (a `../`-relative reference, as stored in an
 * image node's `src`) against `pageDir`, the directory the referencing page
 * lives in. Pure segment math, no filesystem access — mirrors
 * `Valea.Paths.relative/2`'s inverse on the backend. `pageDir` is always
 * ICM-relative (Task 9.6: Phase 4's `(mount_key, ICM-relative path)` re-key
 * collapsed the old "leading slash ⇒ external mount" vocabulary this used
 * to preserve on output — mount identity now rides `mountKey`, a separate
 * value passed alongside the path, never a leading `/` on the path itself).
 */
export function joinRelative(pageDir: string, rel: string): string {
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

  return stack.join('/');
}

const EXTERNAL_SRC_RE = /^(?:https?:|data:)/i;

/**
 * Maps an image node's on-disk `src` (ICM-relative-from-page) to a
 * `/files/raw?mount_key=...&path=...` URL for DISPLAY — matching
 * `FilesController.serve/2`'s `(mount_key, ICM-relative path)` addressing
 * exactly (backend/lib/valea_web/controllers/files_controller.ex; Task 9.6
 * fixes the ledger'd bug where this omitted `mount_key` entirely, 404-ing a
 * freshly-uploaded image's `<img>` re-render). `mountKey` is the page's own
 * mount (`PageEditor.svelte`'s prop, threaded straight through — never
 * re-derived here). `http(s):` and `data:` sources (not produced by this
 * app's own upload flow, but valid hand-authored markdown) pass through
 * unchanged — they're already directly renderable and have nothing to
 * resolve against the page's location or mount.
 */
export function resolveImageSrc(src: string, mountKey: string, pagePath: string): string {
  if (EXTERNAL_SRC_RE.test(src)) return src;

  const resolved = joinRelative(dirnameOf(pagePath), src);
  return `/files/raw?mount_key=${encodeURIComponent(mountKey)}&path=${encodeURIComponent(resolved)}`;
}
