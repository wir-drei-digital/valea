/**
 * Pure decision logic for non-.md file leaves (A-T15 fix wave) — which
 * VIEWER a file's `ext` opens in, and the small uppercase ext label shown
 * beside the name in the Knowledge list panes. Same "extract the logic, no
 * component render harness" convention as `mount-sections.ts`.
 *
 * `ext` comes from `Valea.ICM.tree/0`'s `:file` leaves — already lowercase
 * with the leading dot (e.g. `".pdf"`); the mapping re-lowercases
 * defensively anyway.
 *
 * The two exports are DIFFERENT partitions and neither may be borrowed for
 * the other's job (final review, I1): `fileLeafKind` is the viewer bucket
 * (`FileView` is its only consumer), `fileLeafLabel` is a display string
 * (`IcmTree`'s rows). A third partition lives server-side and is not
 * mirrored here at all — `ValeaWeb.FilesController`'s `@allowed_types` is
 * the CREDENTIAL split for `/files/raw`, i.e. which extensions an `<img>`
 * tag may fetch without the control token.
 */

export type FileLeafKind = 'image' | 'pdf' | 'csv' | 'other';

// Exactly the token-EXEMPT set of `@allowed_types` server-side, and that is
// not a coincidence: `ImageView` renders a bare `<img>`, which cannot send
// the control token, so an ext in here that the route requires a token for
// is a guaranteed 404. `.svg` is the one that bit — it is deliberately
// absent (the route serves SVG as inert `text/plain`, never
// `image/svg+xml`), so it falls through to the tokened `PlainTextView` and
// renders as its own source.
const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp']);

/** Viewer bucket for a file leaf's ext — image/pdf/csv/other, which is what `FileView` dispatches on. */
export function fileLeafKind(ext: string | null | undefined): FileLeafKind {
  const normalized = ext?.toLowerCase() ?? '';
  if (IMAGE_EXTS.has(normalized)) return 'image';
  if (normalized === '.pdf') return 'pdf';
  // `.csv` only: `.tsv` and friends stay plain text until a real file asks
  // for them — `CsvView` sniffs the separator, but the VIEWER choice here
  // is a promise about the format, not a guess.
  if (normalized === '.csv') return 'csv';
  return 'other';
}

/** "PDF"/"PNG"-style label (ext uppercased, dot stripped); "FILE" when the ext is missing/blank. */
export function fileLeafLabel(ext: string | null | undefined): string {
  const stripped = (ext ?? '').replace(/^\./, '').trim();
  return stripped ? stripped.toUpperCase() : 'FILE';
}
