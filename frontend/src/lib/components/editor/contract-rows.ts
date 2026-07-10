/**
 * Derives the read-only "Contract" fact rows PageMeta shows above the
 * ownership card for a workflow page. Pulled out of the component so the
 * derivation itself is unit-testable (PageMeta.svelte has no render-test
 * harness in this codebase — see the other *.test.ts files alongside
 * components' logic modules for the convention).
 *
 * Only scalar/flat values ever surface here: `enabled`, `risk_level`,
 * `trigger.source`, and `sources` (as a count). Anything else in the
 * frontmatter — nested `approval`/`audit` blocks, unknown keys — is left for
 * the raw view; this is a glanceable summary, not a YAML viewer, and it
 * carries no editing affordance.
 */

export type ContractRow = { label: string; value: string };

function scalar(value: unknown): string | null {
  if (typeof value === 'string' || typeof value === 'number' || typeof value === 'boolean') {
    return String(value);
  }
  return null;
}

export function contractRowsFor(frontmatter: Record<string, unknown> | null | undefined): ContractRow[] {
  if (!frontmatter) return [];
  const rows: ContractRow[] = [];

  const enabled = scalar(frontmatter.enabled);
  if (enabled !== null) rows.push({ label: 'enabled', value: enabled });

  const riskLevel = scalar(frontmatter.risk_level);
  if (riskLevel !== null) rows.push({ label: 'risk_level', value: riskLevel });

  const trigger = frontmatter.trigger;
  if (trigger && typeof trigger === 'object' && !Array.isArray(trigger)) {
    const source = scalar((trigger as Record<string, unknown>).source);
    if (source !== null) rows.push({ label: 'trigger.source', value: source });
  }

  const sources = frontmatter.sources;
  if (Array.isArray(sources)) {
    rows.push({ label: 'sources', value: `${sources.length} source${sources.length === 1 ? '' : 's'}` });
  }

  return rows;
}
