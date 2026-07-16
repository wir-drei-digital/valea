import { describe, expect, it } from 'vitest';
import { groupReferences, impactLine, deleteImpactLine, type PageRef } from './backlinks-panel';

const page: PageRef = { sourcePath: 'mounts/primary/Offers/Intro.md', mount: 'primary', linkText: 'the intro' };
const page2: PageRef = { sourcePath: 'mounts/primary/Offers/Follow-up.md', mount: 'primary', linkText: 'follow up' };

describe('groupReferences', () => {
  it('passes pages through unchanged when present and non-empty', () => {
    expect(groupReferences({ pages: [page] })).toEqual({
      pages: [page],
      empty: false
    });
  });

  it('defaults pages to [] when the field is entirely absent (a stale cached client)', () => {
    expect(groupReferences({})).toEqual({ pages: [], empty: true });
  });

  it('defaults a null field to [], same as an absent one', () => {
    expect(groupReferences({ pages: null })).toEqual({ pages: [], empty: true });
  });

  it('reports empty: true when pages is an empty array', () => {
    expect(groupReferences({ pages: [] })).toEqual({ pages: [], empty: true });
  });

  it('reports empty: false when pages has entries', () => {
    expect(groupReferences({ pages: [page, page2] }).empty).toBe(false);
  });
});

describe('impactLine', () => {
  it('returns null when the count is zero', () => {
    expect(impactLine(0)).toBeNull();
  });

  it('singularizes a page count of 1', () => {
    expect(impactLine(1)).toBe('Also updates 1 page that reads this page.');
  });

  it('pluralizes a page count greater than 1', () => {
    expect(impactLine(2)).toBe('Also updates 2 pages that read this page.');
  });
});

describe('deleteImpactLine', () => {
  it('returns null when the count is zero', () => {
    expect(deleteImpactLine(0)).toBeNull();
  });

  it('singularizes a page count of 1', () => {
    expect(deleteImpactLine(1)).toBe('1 page references this page and will lose the link.');
  });

  it('pluralizes a page count greater than 1', () => {
    expect(deleteImpactLine(2)).toBe('2 pages reference this page and will lose the link.');
  });
});
