import { describe, it, expect } from 'vitest';
import { mountProvenanceLabel, workflowEditHref } from './workflowHref';

describe('workflowEditHref', () => {
  it('path-encodes each segment of a mounts/-namespaced workflow path (A-T15: paths are workspace-relative, no icm/ prefix to strip)', () => {
    expect(workflowEditHref('mounts/primary/Workflows/New Inquiry Triage.md')).toBe(
      '/knowledge/mounts/primary/Workflows/New%20Inquiry%20Triage.md'
    );
  });

  it('returns null for a path that does not start with mounts/', () => {
    expect(workflowEditHref('icm/Workflows/New Inquiry Triage.md')).toBeNull();
    expect(workflowEditHref('workflows/New Inquiry Triage.md')).toBeNull();
    expect(workflowEditHref('')).toBeNull();
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
