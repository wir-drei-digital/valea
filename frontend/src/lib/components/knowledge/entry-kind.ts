/**
 * What kind of thing a knowledge row addresses. `EntryMenu` and the
 * Rename/Delete dialogs used to take a boolean `isFolder`, which could only
 * say folder-or-not — fine while every non-folder row was a `.md` page, but
 * the side-panes pass made non-.md file leaves (PDFs, images, LICENSE)
 * navigable, and those need copy and gates of their own:
 *
 *   - `folder` — no reference lookup (the backend's reference search
 *     resolves one exact target path, not a folder-scoped query), no
 *     session action.
 *   - `page` — a `.md` page: reference lookup, `.md`-shaped rename on the
 *     backend (typing "Weekly notes" writes "Weekly notes.md").
 *   - `file` — any other regular file: reference lookup works exactly the
 *     same (an embedded image IS a confirmed Link/Image destination — see
 *     `Valea.ICM.Backlinks`), rename takes the name as typed.
 *
 * Rename and Delete are offered for all three. Kind only changes the words.
 */
export type EntryKind = 'folder' | 'page' | 'file';

/**
 * Label for the "start a session with this…" menu item. Never rendered for
 * a folder (the action needs one exact file to hand the agent), so a folder
 * falls through to the page wording rather than earning a third string.
 */
export function startSessionLabel(kind: EntryKind): string {
  return kind === 'file' ? 'Start a session with this file' : 'Start a session with this page';
}

/**
 * The noun the reference-impact copy should use for the rename/delete
 * TARGET ("…that read this page" vs "…that read this file"). The pages
 * doing the referencing are always pages — only the target varies.
 */
export function referenceNoun(kind: EntryKind): 'page' | 'file' {
  return kind === 'file' ? 'file' : 'page';
}
