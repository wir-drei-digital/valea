/**
 * "· <mount>" provenance chip label — the owning ICM's manifest display
 * name (renamed from `mount` in Task 7.1's registry re-key; relocated here
 * from the deleted `components/workflows/workflowHref.ts` in the Spec D
 * deletion wave, verbatim, since `AuditRow.svelte` still needs it for its
 * per-entry "· <mount>" chip). `null` when the name is missing or blank (a
 * stale cache from before the RPC exposed this field, or a defensively-blank
 * manifest name) so the caller renders no chip at all rather than a bare "·".
 */
export function mountProvenanceLabel(mount: string | null | undefined): string | null {
  const trimmed = mount?.trim();
  return trimmed ? `· ${trimmed}` : null;
}
