/**
 * Knowledge-page href for a workflow's "Edit →" link. `workflow.path` (from
 * `WorkflowsStore`/`list_workflows`) is WORKSPACE-relative, e.g.
 * `"icm/Workflows/New Inquiry Triage.md"` (see `Valea.Workflows.parse/2`:
 * `path: Path.relative_to(abs, workspace)`). The Knowledge route's paths are
 * relative to the `icm/` root itself and never carry that prefix
 * (`Valea.ICM.tree/0` computes `path` relative to `icm/`, confirmed against
 * `icmToNav`'s `/knowledge/${encodePath(n.path)}` in `lib/shell/nav.ts`) —
 * same "icm/ prefix, strip before linking" move as
 * `components/queue/sourceDot.ts`'s `sourceHref`.
 *
 * Falls back to `null` for a path that (defensively) doesn't start with
 * `"icm/"` so a malformed entry never produces a broken half-built link.
 */
export function workflowEditHref(path: string): string | null {
  if (!path.startsWith('icm/')) return null;
  const relative = path.slice('icm/'.length);
  return `/knowledge/${relative.split('/').map(encodeURIComponent).join('/')}`;
}
