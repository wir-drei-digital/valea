import { describe, it, expect } from 'vitest';
import { mountProvenanceLabel, workflowEditHref } from './workflowHref';

describe('workflowEditHref', () => {
  // Fix-wave Finding 3 (task-9.6-report.md): the old signature built
  // `/knowledge/${encodePath(resolvedPath)}` from `workflow.resolvedPath` —
  // an ABSOLUTE physical path in practice (A2-T5b: every mount is external
  // now) — landing on `/knowledge/<absolute-path-with-no-mountKey-segment>`,
  // which the `/knowledge/[...path]` route parses as an empty `mountKey`
  // and silently renders the empty Knowledge root instead of the workflow's
  // page. `list_workflows` already returns `mountKey` and `relativePath` on
  // every `WorkflowListItem` (`ash_rpc.ts`'s `ListWorkflowsFields`, Task
  // 7.1's re-key) — this rebuilds the href from those two fields instead,
  // reusing `knowledgeHref` (`$lib/shell/nav`) so the encoding stays
  // byte-for-byte identical to every other Knowledge-page link in the app.
  it('builds /knowledge/<mountKey>/<encoded relativePath> from the list_workflows RPC fields', () => {
    expect(workflowEditHref('primary', 'Workflows/New Inquiry Triage.md')).toBe(
      '/knowledge/primary/Workflows/New%20Inquiry%20Triage.md'
    );
  });

  it('encodes a mount key that itself needs escaping, same as knowledgeHref', () => {
    expect(workflowEditHref('client docs', 'Workflows/Triage.md')).toBe(
      '/knowledge/client%20docs/Workflows/Triage.md'
    );
  });

  it('path-encodes a nested relativePath segment by segment', () => {
    expect(workflowEditHref('primary', 'Workflows/Inbound/New Inquiry Triage.md')).toBe(
      '/knowledge/primary/Workflows/Inbound/New%20Inquiry%20Triage.md'
    );
  });

  it('returns null when mountKey is missing/blank', () => {
    expect(workflowEditHref('', 'Workflows/Triage.md')).toBeNull();
    expect(workflowEditHref('   ', 'Workflows/Triage.md')).toBeNull();
  });

  it('returns null when relativePath is missing/blank', () => {
    expect(workflowEditHref('primary', '')).toBeNull();
    expect(workflowEditHref('primary', '   ')).toBeNull();
  });
});

describe('mountProvenanceLabel', () => {
  it('formats "· <mount>" for a present, non-blank mount name', () => {
    expect(mountProvenanceLabel('Primary')).toBe('· Primary');
    expect(mountProvenanceLabel('Client Docs')).toBe('· Client Docs');
  });

  it('returns null for a missing/blank mount so the chip renders nothing', () => {
    expect(mountProvenanceLabel(undefined)).toBeNull();
    expect(mountProvenanceLabel(null)).toBeNull();
    expect(mountProvenanceLabel('')).toBeNull();
    expect(mountProvenanceLabel('   ')).toBeNull();
  });
});
