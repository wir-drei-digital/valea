/**
 * Pure grouping/copy logic for `BacklinksPanel` and the page-aware impact
 * lines in RenameDialog/DeleteDialog (Task C10). Consumes the
 * `icm_entry_references` RPC result — `{pages: [{sourcePath, mount,
 * linkText}]}`, already camelCased by ash_typescript (see
 * `icmEntryReferencesFields`'s comment in `api/client.ts`). Page-link
 * references only (Spec D §A) — the workflow-frontmatter reference union
 * was deleted; page-link rename integrity remains `Valea.ICM.LinkRewrite`'s
 * job.
 */

export type PageRef = { sourcePath: string; mount: string; linkText: string };

/**
 * `pages` is deliberately optional/nullable here, not just `PageRef[]` — a
 * caller running against a stale cached client bundle delivers a result
 * with no `pages` key at all, not an empty array. `groupReferences` guards
 * that with `?? []` rather than assuming the field is always present.
 */
export type RawReferences = { pages?: PageRef[] | null };

export type GroupedReferences = { pages: PageRef[]; empty: boolean };

export function groupReferences(refs: RawReferences): GroupedReferences {
  const pages = refs.pages ?? [];
  return { pages, empty: pages.length === 0 };
}

/**
 * "Also updates …" copy for the Rename/Delete dialogs' impact line (and
 * `BacklinksPanel`'s own summary) — singular/plural, `null` when no page
 * reads this entry (nothing to say, so callers render nothing rather than
 * an empty sentence).
 *
 * `target` names what is BEING renamed/deleted — a `.md` page by default,
 * `'file'` when the row is a non-.md file leaf (an embedded image, a PDF).
 * The referencing side is always pages either way: only a page can hold a
 * link.
 */
export function impactLine(pageCount: number, target: 'page' | 'file' = 'page'): string | null {
  if (pageCount === 0) return null;

  const verb = pageCount === 1 ? 'reads' : 'read';
  return `Also updates ${pageCount} ${pageCount === 1 ? 'page' : 'pages'} that ${verb} this ${target}.`;
}

/**
 * Delete-appropriate impact line for the Delete dialog — frames deletion's
 * consequences clearly: pages that reference this entry "will lose the
 * link" rather than being "updated". Matches `impactLine`'s singular/plural
 * structure, but conveys that deletion BREAKS the reference rather than
 * maintaining it.
 *
 * Returns `null` when the count is zero (nothing to say). `target` names
 * what is being deleted, exactly as in `impactLine`.
 */
export function deleteImpactLine(
  pageCount: number,
  target: 'page' | 'file' = 'page'
): string | null {
  if (pageCount === 0) return null;

  const verb = pageCount === 1 ? 'references' : 'reference';
  return `${pageCount} ${pageCount === 1 ? 'page' : 'pages'} ${verb} this ${target} and will lose the link.`;
}
