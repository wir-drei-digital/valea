import { describe, expect, it } from 'vitest';
import { icmToNav, encodePath, flattenMountGroups, type IcmNode } from './nav';

const tree: IcmNode[] = [
  {
    name: 'Tone & Voice',
    path: 'Tone & Voice',
    type: 'folder',
    pageCount: 2,
    children: [
      { name: 'Email Tone Guide', path: 'Tone & Voice/Email Tone Guide.md', type: 'page', uri: 'icm://Tone & Voice/Email Tone Guide.md' }
    ]
  }
];

describe('icmToNav', () => {
  it('maps folders with counts and encoded hrefs', () => {
    const nav = icmToNav(tree);
    expect(nav[0].label).toBe('Tone & Voice');
    expect(nav[0].count).toBe(2);
    expect(nav[0].children?.[0].href).toBe('/knowledge/Tone%20%26%20Voice/Email%20Tone%20Guide.md');
  });
});

describe('encodePath', () => {
  it('encodes segments but keeps separators', () => {
    expect(encodePath('A B/C&D.md')).toBe('A%20B/C%26D.md');
  });
});

// Replaces the deleted `IcmStore.nodes` back-compat getter (A-T15) — every
// consumer that just needs a single flat search/nav list (not a per-mount
// grouped display) flattens `icmStore.groups` through this instead.
describe('flattenMountGroups', () => {
  const nodeA: IcmNode = { name: 'A', path: 'mounts/primary/A', type: 'page', uri: 'icm://mounts/primary/A' };
  const nodeB: IcmNode = { name: 'B', path: 'mounts/clients/B', type: 'page', uri: 'icm://mounts/clients/B' };

  it('flattens every group\'s tree into a single array, in group order', () => {
    const groups = [{ tree: [nodeA] }, { tree: [nodeB] }];
    expect(flattenMountGroups(groups)).toEqual([nodeA, nodeB]);
  });

  it('returns [] for an empty groups array', () => {
    expect(flattenMountGroups([])).toEqual([]);
  });

  it('skips a group with an empty tree without dropping the others', () => {
    const groups = [{ tree: [] }, { tree: [nodeB] }];
    expect(flattenMountGroups(groups)).toEqual([nodeB]);
  });
});
