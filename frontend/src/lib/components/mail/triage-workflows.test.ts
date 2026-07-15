import { describe, it, expect } from 'vitest';
import { triageCandidates } from './triage-workflows';
import type { WorkflowListItem } from '$lib/stores/workflows.svelte';

function workflow(overrides: Partial<WorkflowListItem> = {}): WorkflowListItem {
  return {
    icmId: 'icm-1',
    mountKey: 'primary',
    relativePath: 'Workflows/New Inquiry Triage.md',
    resolvedPath: '/workspace/primary/Workflows/New Inquiry Triage.md',
    name: 'New Inquiry Triage',
    enabled: true,
    riskLevel: 'medium',
    icmName: 'Mara Lindt Coaching',
    ...overrides
  };
}

describe('triageCandidates', () => {
  it('returns a single candidate untouched when only one enabled mount carries the workflow', () => {
    const result = triageCandidates([workflow()]);
    expect(result).toEqual([
      { mountKey: 'primary', relativePath: 'Workflows/New Inquiry Triage.md', icmName: 'Mara Lindt Coaching' }
    ]);
  });

  it('returns one candidate per enabled mount that carries its own copy, sorted by ICM name', () => {
    const result = triageCandidates([
      workflow({ mountKey: 'zzz', icmName: 'Zebra Studio', relativePath: 'Workflows/New Inquiry Triage.md' }),
      workflow({ mountKey: 'aaa', icmName: 'Acme Coaching', relativePath: 'Workflows/New Inquiry Triage.md' })
    ]);
    expect(result.map((c) => c.icmName)).toEqual(['Acme Coaching', 'Zebra Studio']);
    expect(result.map((c) => c.mountKey)).toEqual(['aaa', 'zzz']);
  });

  it('excludes a disabled workflow (never a runnable candidate)', () => {
    const result = triageCandidates([workflow({ enabled: false })]);
    expect(result).toEqual([]);
  });

  it('excludes any workflow whose file is not named "New Inquiry Triage.md"', () => {
    const result = triageCandidates([
      workflow({ relativePath: 'Workflows/Session Prep.md', name: 'Session Prep' })
    ]);
    expect(result).toEqual([]);
  });

  it('matches by basename regardless of nesting depth', () => {
    const result = triageCandidates([workflow({ relativePath: 'Workflows/Inbound/New Inquiry Triage.md' })]);
    expect(result).toHaveLength(1);
  });

  it('falls back to mountKey when icmName is missing or blank', () => {
    const missing = triageCandidates([workflow({ icmName: undefined })]);
    expect(missing[0].icmName).toBe('primary');

    const blank = triageCandidates([workflow({ icmName: '   ' })]);
    expect(blank[0].icmName).toBe('primary');
  });

  it('returns an empty list for an empty catalog', () => {
    expect(triageCandidates([])).toEqual([]);
  });

  it('breaks a tied icmName by mountKey for a fully deterministic order', () => {
    const result = triageCandidates([
      workflow({ mountKey: 'zzz', icmName: 'Same Name' }),
      workflow({ mountKey: 'aaa', icmName: 'Same Name' })
    ]);
    expect(result.map((c) => c.mountKey)).toEqual(['aaa', 'zzz']);
  });
});
