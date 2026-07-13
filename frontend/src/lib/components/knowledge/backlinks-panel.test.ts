import { describe, expect, it } from 'vitest';
import { groupReferences, impactLine, type PageRef, type WorkflowRef } from './backlinks-panel';

const page: PageRef = { sourcePath: 'mounts/primary/Offers/Intro.md', mount: 'primary', linkText: 'the intro' };
const page2: PageRef = { sourcePath: 'mounts/primary/Offers/Follow-up.md', mount: 'primary', linkText: 'follow up' };
const workflow: WorkflowRef = { file: 'mounts/primary/Workflows/Triage.md', name: 'Triage' };

describe('groupReferences', () => {
  it('passes both groups through unchanged when both are present and non-empty', () => {
    expect(groupReferences({ pages: [page], workflows: [workflow] })).toEqual({
      pages: [page],
      workflows: [workflow],
      empty: false
    });
  });

  it('defaults pages to [] when the field is entirely absent (a not-yet-C3 cached client)', () => {
    expect(groupReferences({ workflows: [workflow] })).toEqual({
      pages: [],
      workflows: [workflow],
      empty: false
    });
  });

  it('defaults workflows to [] when the field is entirely absent', () => {
    expect(groupReferences({ pages: [page] })).toEqual({
      pages: [page],
      workflows: [],
      empty: false
    });
  });

  it('defaults a null field to [], same as an absent one', () => {
    expect(groupReferences({ pages: null, workflows: null })).toEqual({ pages: [], workflows: [], empty: true });
  });

  it('reports empty: true when both groups are empty arrays', () => {
    expect(groupReferences({ pages: [], workflows: [] })).toEqual({ pages: [], workflows: [], empty: true });
  });

  it('reports empty: true when both fields are entirely absent', () => {
    expect(groupReferences({})).toEqual({ pages: [], workflows: [], empty: true });
  });

  it('reports empty: false when only one group has entries', () => {
    expect(groupReferences({ pages: [page, page2], workflows: [] }).empty).toBe(false);
    expect(groupReferences({ pages: [], workflows: [workflow] }).empty).toBe(false);
  });
});

describe('impactLine', () => {
  it('returns null when both counts are zero', () => {
    expect(impactLine(0, 0)).toBeNull();
  });

  it('singularizes a lone page count of 1', () => {
    expect(impactLine(1, 0)).toBe('Also updates 1 page that reads this page.');
  });

  it('pluralizes a lone page count greater than 1', () => {
    expect(impactLine(2, 0)).toBe('Also updates 2 pages that read this page.');
  });

  it('singularizes a lone workflow count of 1', () => {
    expect(impactLine(0, 1)).toBe('Also updates 1 workflow that reads this page.');
  });

  it('pluralizes a lone workflow count greater than 1', () => {
    expect(impactLine(0, 2)).toBe('Also updates 2 workflows that read this page.');
  });

  it('joins both kinds with "and" and uses the plural verb even when each part is singular', () => {
    expect(impactLine(1, 1)).toBe('Also updates 1 page and 1 workflow that read this page.');
  });

  it('matches the brief\'s exact example copy for a mixed plural/singular pair', () => {
    expect(impactLine(2, 1)).toBe('Also updates 2 pages and 1 workflow that read this page.');
  });

  it('pluralizes both parts when both counts are greater than 1', () => {
    expect(impactLine(1, 2)).toBe('Also updates 1 page and 2 workflows that read this page.');
  });
});
