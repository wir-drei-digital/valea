import { knowledgeHref } from '$lib/shell/nav';

/**
 * Knowledge-page href for a workflow's "Edit →" link.
 *
 * Fix-wave Finding 3 (task-9.6-report.md): this used to build
 * `/knowledge/${encodePath(workflow.resolvedPath)}` from `resolvedPath` — an
 * ABSOLUTE physical path in practice, since A2-T5b made every mount
 * external. That produced a URL with NO `mountKey` path segment at all
 * (`/knowledge//Users/dana/Client Docs/…`); the `/knowledge/[...path]`
 * route reads the first segment as `mountKey`, so this silently landed on
 * `mountKey === ''` — the empty Knowledge root — instead of the workflow's
 * page (`WorkflowCard.svelte`'s "Edit →" link was live-broken).
 *
 * `list_workflows` already returns `mountKey` and `relativePath`
 * (ICM-relative, e.g. `"Workflows/New Inquiry Triage.md"`) on every
 * `WorkflowListItem` (`ash_rpc.ts`'s `ListWorkflowsFields`, Task 7.1's
 * `{icmId, relativePath}` identity re-key) — those are the correct
 * addressing pair, `resolvedPath` was never the right input. Reuses
 * `knowledgeHref` (`$lib/shell/nav`) rather than re-encoding, so this stays
 * byte-for-byte the same encoding as every other Knowledge-page link
 * (`icmToNav`, `PageEditor.svelte`'s own navigation) for the same
 * `(mountKey, path)` pair.
 *
 * Falls back to `null` when `mountKey` or `relativePath` is blank so a
 * malformed/stale-cache entry never produces a broken half-built link.
 */
export function workflowEditHref(mountKey: string, relativePath: string): string | null {
  if (!mountKey.trim() || !relativePath.trim()) return null;
  return knowledgeHref(mountKey, relativePath);
}

/**
 * "· <mount>" provenance chip label for `WorkflowCard.svelte` — the owning
 * ICM's manifest display name (`WorkflowListItem.icmName`, A-T15, renamed
 * from `mount` in Task 7.1's registry re-key). `null` when the name is
 * missing or blank (a stale cache from before the RPC exposed this field,
 * or a defensively-blank manifest name) so the caller renders no chip at
 * all rather than a bare "·".
 */
export function mountProvenanceLabel(mount: string | null | undefined): string | null {
  const trimmed = mount?.trim();
  return trimmed ? `· ${trimmed}` : null;
}
