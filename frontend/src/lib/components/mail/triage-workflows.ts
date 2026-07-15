/**
 * Pure helpers for Mail's "Run triage" action entry point (`MessageView.svelte`)
 * — Task 9.5: "Mail and calendar do not choose an ICM themselves. An action
 * launched from them must select an ICM or a workflow that already
 * identifies one" (spec §"Workspace-wide views"). Before this task, the
 * action always ran the cockpit payload's single SEEDED triage workflow
 * (`Valea.Cockpit.today/0`'s `triage_workflow_path` — the first enabled
 * mount, by the registry's own sort order, that happens to carry a
 * `Workflows/New Inquiry Triage.md`) — silently picking one ICM out from
 * under a message that could belong to any of them once more than one
 * mount carries the contract. `triageCandidates` instead surfaces EVERY
 * enabled ICM's own copy, so the action can run directly when there's
 * exactly one (a workflow that already identifies its ICM — no picker
 * needed) and otherwise ask via a compact picker (`MessageView.svelte`'s
 * `DropdownMenu`, same primitive `NewEntryButton.svelte` uses).
 *
 * Field shapes are sourced from `WorkflowsStore`/`listWorkflowsFields`
 * (`stores/workflows.svelte.ts`) — `mountKey`, `relativePath` (ICM-relative,
 * e.g. `"Workflows/New Inquiry Triage.md"`), `enabled`, and `icmName` (the
 * owning mount's manifest display name, `null`/blank for a stale cache
 * entry — same defensive fallback `workflowHref.ts`'s
 * `mountProvenanceLabel` documents).
 */
import type { WorkflowListItem } from '$lib/stores/workflows.svelte';

// Mirrors `Valea.Workflows`'s `@triage_filename` module attribute exactly —
// the one basename every mount's own copy of the seeded contract must have
// to be discovered, on either side of this boundary.
const TRIAGE_FILENAME = 'New Inquiry Triage.md';

export type TriageCandidate = {
  mountKey: string;
  relativePath: string;
  /** The owning ICM's display name — falls back to `mountKey` for a blank/missing manifest name, never a bare "· " label. */
  icmName: string;
};

function basename(path: string): string {
  const parts = path.split('/');
  return parts[parts.length - 1] ?? path;
}

/**
 * Every ENABLED workflow across every enabled mount named
 * `"New Inquiry Triage.md"` — Mail's candidate list for "Run triage",
 * sorted by display name for a stable, predictable picker order (ties
 * broken by `mountKey` so the order is fully deterministic).
 */
export function triageCandidates(workflows: WorkflowListItem[]): TriageCandidate[] {
  return workflows
    .filter((wf) => wf.enabled && basename(wf.relativePath) === TRIAGE_FILENAME)
    .map((wf) => ({
      mountKey: wf.mountKey,
      relativePath: wf.relativePath,
      icmName: wf.icmName?.trim() || wf.mountKey
    }))
    .sort((a, b) => a.icmName.localeCompare(b.icmName) || a.mountKey.localeCompare(b.mountKey));
}
