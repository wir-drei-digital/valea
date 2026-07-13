/**
 * Pure grouping/copy logic for `BacklinksPanel` and the page-aware impact
 * lines in RenameDialog/DeleteDialog (Task C10). Consumes C3's
 * `icm_entry_references` RPC result — `{workflows: [{file, name}], pages:
 * [{sourcePath, mount, linkText}]}`, already camelCased by ash_typescript
 * (see `icmEntryReferencesFields`'s comment in `api/client.ts`).
 */

export type WorkflowRef = { file: string; name: string };
export type PageRef = { sourcePath: string; mount: string; linkText: string };

/**
 * `pages` is deliberately optional/nullable here, not just `PageRef[]` — a
 * caller running against a not-yet-C3 cached client bundle (or any future
 * caller that only asks the RPC for `workflows`) delivers a result with no
 * `pages` key at all, not an empty array. `groupReferences` guards that with
 * `?? []` rather than assuming the field is always present.
 */
export type RawReferences = { workflows?: WorkflowRef[] | null; pages?: PageRef[] | null };

export type GroupedReferences = { pages: PageRef[]; workflows: WorkflowRef[]; empty: boolean };

export function groupReferences(refs: RawReferences): GroupedReferences {
  const pages = refs.pages ?? [];
  const workflows = refs.workflows ?? [];
  return { pages, workflows, empty: pages.length === 0 && workflows.length === 0 };
}

/**
 * "Also updates …" copy for the Rename/Delete dialogs' impact line (and
 * `BacklinksPanel`'s own summary) — singular/plural per kind, "and"-joined
 * when both kinds are present, `null` when neither a page nor a workflow
 * reads this entry (nothing to say, so callers render nothing rather than
 * an empty sentence).
 *
 * The verb stays "read" (not "reads") whenever more than one thing is being
 * updated — either kind's count is itself plural, or both kinds are present
 * at all: a compound "X and Y" subject takes a plural verb even when each
 * part is singular ("1 page and 1 workflow that read this page").
 */
export function impactLine(pageCount: number, workflowCount: number): string | null {
  if (pageCount === 0 && workflowCount === 0) return null;

  const pagePart = pageCount > 0 ? `${pageCount} ${pageCount === 1 ? 'page' : 'pages'}` : null;
  const workflowPart =
    workflowCount > 0 ? `${workflowCount} ${workflowCount === 1 ? 'workflow' : 'workflows'}` : null;

  if (pagePart && workflowPart) {
    return `Also updates ${pagePart} and ${workflowPart} that read this page.`;
  }

  // Exactly one of the two parts is set (the both-zero case returned above).
  const soleCount = pageCount || workflowCount;
  const verb = soleCount === 1 ? 'reads' : 'read';
  return `Also updates ${pagePart ?? workflowPart} that ${verb} this page.`;
}

/**
 * Delete-appropriate impact line for the Delete dialog — uses "reference" and
 * "reads" verbs (like `impactLine`) but frames deletion's consequences clearly:
 * pages/workflows that reference this entry "will lose the link" or "will lose
 * the reference" rather than being "updated". Matches `impactLine`'s structure
 * exactly (singular/plural per kind, compound subjects with plural verb), but
 * conveys that deletion BREAKS references rather than maintaining them.
 *
 * Returns `null` when both counts are zero (nothing to say).
 */
export function deleteImpactLine(pageCount: number, workflowCount: number): string | null {
  if (pageCount === 0 && workflowCount === 0) return null;

  const pagePart = pageCount > 0 ? `${pageCount} ${pageCount === 1 ? 'page' : 'pages'}` : null;
  const workflowPart =
    workflowCount > 0 ? `${workflowCount} ${workflowCount === 1 ? 'workflow' : 'workflows'}` : null;

  if (pagePart && workflowPart) {
    return `${pagePart} and ${workflowPart} reference this page and will lose the link.`;
  }

  // Exactly one of the two parts is set (the both-zero case returned above).
  if (pagePart) {
    const verb = pageCount === 1 ? 'references' : 'reference';
    return `${pagePart} ${verb} this page and will lose the link.`;
  }

  // Only workflows
  const verb = workflowCount === 1 ? 'reads' : 'read';
  return `${workflowPart} ${verb} this page and will lose the reference.`;
}
