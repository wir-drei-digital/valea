import { describe, it, expect } from 'vitest';
import { workflowEditHref } from './workflowHref';

describe('workflowEditHref', () => {
  it('strips the icm/ prefix and path-encodes each segment', () => {
    expect(workflowEditHref('icm/Workflows/New Inquiry Triage.md')).toBe(
      '/knowledge/Workflows/New%20Inquiry%20Triage.md'
    );
  });

  it('returns null for a path that does not start with icm/', () => {
    expect(workflowEditHref('workflows/New Inquiry Triage.md')).toBeNull();
    expect(workflowEditHref('')).toBeNull();
  });
});
