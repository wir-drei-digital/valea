/**
 * Pure decision logic for non-.md file leaf rows in the Knowledge list
 * panes (A-T15 fix wave) — which icon family a file's `ext` maps to, and
 * the small uppercase ext label shown beside the name. Same "extract the
 * logic, no component render harness" convention as `mount-sections.ts`.
 *
 * `ext` comes from `Valea.ICM.tree/0`'s `:file` leaves — already lowercase
 * with the leading dot (e.g. `".pdf"`); the mapping re-lowercases
 * defensively anyway.
 */

export type FileLeafKind = 'image' | 'pdf' | 'other';

const IMAGE_EXTS = new Set(['.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg']);

/** Icon-family bucket for a file leaf's ext — the simple image/pdf/other mapping the row's icon keys on. */
export function fileLeafKind(ext: string | null | undefined): FileLeafKind {
  const normalized = ext?.toLowerCase() ?? '';
  if (IMAGE_EXTS.has(normalized)) return 'image';
  if (normalized === '.pdf') return 'pdf';
  return 'other';
}

/** "PDF"/"PNG"-style label (ext uppercased, dot stripped); "FILE" when the ext is missing/blank. */
export function fileLeafLabel(ext: string | null | undefined): string {
  const stripped = (ext ?? '').replace(/^\./, '').trim();
  return stripped ? stripped.toUpperCase() : 'FILE';
}
