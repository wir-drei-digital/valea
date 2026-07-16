import { describe, it, expect } from 'vitest';
import { mountProvenanceLabel } from './provenance';

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
