import { describe, it, expect } from 'vitest';
import { contractRowsFor } from './contract-rows';

describe('contractRowsFor', () => {
  it('returns no rows for null/undefined frontmatter', () => {
    expect(contractRowsFor(null)).toEqual([]);
    expect(contractRowsFor(undefined)).toEqual([]);
  });

  it('returns no rows for frontmatter with none of the known scalar fields', () => {
    expect(contractRowsFor({ approval: { required: true } })).toEqual([]);
  });

  it('surfaces enabled and risk_level as scalar rows', () => {
    const rows = contractRowsFor({ enabled: true, risk_level: 'medium' });

    expect(rows).toEqual([
      { label: 'enabled', value: 'true' },
      { label: 'risk_level', value: 'medium' }
    ]);
  });

  it('surfaces trigger.source from the nested trigger object', () => {
    const rows = contractRowsFor({ trigger: { type: 'manual', source: 'email.selected' } });

    expect(rows).toEqual([{ label: 'trigger.source', value: 'email.selected' }]);
  });

  it('surfaces sources as a count, not the raw list', () => {
    const rows = contractRowsFor({
      sources: [{ id: 'a' }, { id: 'b' }, { id: 'c' }]
    });

    expect(rows).toEqual([{ label: 'sources', value: '3 sources' }]);
  });

  it('uses singular "source" for a single-item list', () => {
    const rows = contractRowsFor({ sources: [{ id: 'a' }] });

    expect(rows).toEqual([{ label: 'sources', value: '1 source' }]);
  });

  it('combines every known field from a realistic workflow frontmatter', () => {
    const rows = contractRowsFor({
      enabled: true,
      risk_level: 'medium',
      trigger: { type: 'manual', source: 'email.selected' },
      sources: [{ id: 'current_email' }, { id: 'tone_guide' }],
      approval: { required: true, reason: 'Email replies must be reviewed before sending.' }
    });

    expect(rows).toEqual([
      { label: 'enabled', value: 'true' },
      { label: 'risk_level', value: 'medium' },
      { label: 'trigger.source', value: 'email.selected' },
      { label: 'sources', value: '2 sources' }
    ]);
  });

  it('ignores a non-scalar trigger.source and a non-array sources value', () => {
    const rows = contractRowsFor({
      trigger: { type: 'manual', source: { nested: true } },
      sources: 'not-an-array'
    });

    expect(rows).toEqual([]);
  });
});
