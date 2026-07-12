/**
 * Knowledge-page href for a workflow's "Edit →" link. `workflow.path` (from
 * `WorkflowsStore`/`list_workflows`) is WORKSPACE-relative, e.g.
 * `"mounts/primary/Workflows/New Inquiry Triage.md"` (see
 * `Valea.Workflows.parse/2`: `path: Path.join(mount.rel_root, ...)`).
 *
 * A-T15: since the mounts refactor (A-T3), `Valea.ICM.tree/0`'s node
 * `path`s are ALSO workspace-relative (`mounts/<name>/…` — see
 * `Valea.ICM.prefix_tree/2`), so the Knowledge route's own paths are now
 * exactly this same `mounts/<name>/…` shape with NO prefix to strip —
 * confirmed against `icmToNav`'s `/knowledge/${encodePath(n.path)}` in
 * `lib/shell/nav.ts`, which encodes a `MountGroup` tree node's `path`
 * verbatim. (Before the mounts refactor this function stripped a leading
 * `"icm/"`; that prefix no longer exists on either side.)
 *
 * Falls back to `null` for a path that (defensively) doesn't start with
 * `"mounts/"` so a malformed or pre-mounts-shaped entry never produces a
 * broken half-built link.
 */
export function workflowEditHref(path: string): string | null {
  if (!path.startsWith('mounts/')) return null;
  return `/knowledge/${path.split('/').map(encodeURIComponent).join('/')}`;
}

/**
 * "· <mount>" provenance chip label for `WorkflowCard.svelte` — the owning
 * mount's manifest display name (`WorkflowListItem.mount`, A-T15). `null`
 * when the mount is missing or blank (a stale cache from before the RPC
 * exposed this field, or a defensively-blank manifest name) so the caller
 * renders no chip at all rather than a bare "·".
 */
export function mountProvenanceLabel(mount: string | null | undefined): string | null {
  const trimmed = mount?.trim();
  return trimmed ? `· ${trimmed}` : null;
}
