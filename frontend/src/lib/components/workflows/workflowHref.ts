import { encodePath } from '$lib/shell/nav';

/**
 * Knowledge-page href for a workflow's "Edit →" link. `workflow.path` (from
 * `WorkflowsStore`/`list_workflows`) is either WORKSPACE-relative, e.g.
 * `"mounts/primary/Workflows/New Inquiry Triage.md"` (see
 * `Valea.Workflows.parse/2`: `path: Path.join(mount.rel_root, ...)`) for an
 * EMBEDDED mount, or an ABSOLUTE physical path (e.g.
 * `"/Users/dana/Client Docs/Workflows/New Inquiry Triage.md"`) for an
 * EXTERNAL (by-reference) one, A2-T5b.
 *
 * A-T15: since the mounts refactor (A-T3), `Valea.ICM.tree/0`'s node
 * `path`s carry the SAME two shapes (`mounts/<name>/…` for embedded,
 * absolute for external — see `Valea.ICM.prefix_tree/2`), so the Knowledge
 * route's own paths are exactly this — with NO prefix to strip — and this
 * reuses `icmToNav`'s own `encodePath` (`lib/shell/nav.ts`) so the two stay
 * byte-for-byte the same encoding for the same path, rather than
 * maintaining a second copy that could drift. (Before the mounts refactor
 * this function stripped a leading `"icm/"`; that prefix no longer exists
 * on either side.)
 *
 * Falls back to `null` for a path that (defensively) is neither
 * workspace-relative (`"mounts/"`-prefixed) nor absolute (`"/"`-prefixed)
 * so a malformed or pre-mounts-shaped entry (e.g. the legacy `"icm/"`
 * prefix) never produces a broken half-built link.
 */
export function workflowEditHref(path: string): string | null {
  if (!path.startsWith('mounts/') && !path.startsWith('/')) return null;
  return `/knowledge/${encodePath(path)}`;
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
