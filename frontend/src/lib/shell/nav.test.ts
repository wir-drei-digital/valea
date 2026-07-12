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

  it('emits NO nav item for file leaves — only .md pages get an editor href (A-T15 fix wave)', () => {
    const withFiles: IcmNode[] = [
      {
        name: 'Offers',
        path: 'mounts/primary/Offers',
        type: 'folder',
        pageCount: 1,
        children: [
          { name: 'Founder', path: 'mounts/primary/Offers/Founder.md', type: 'page', uri: 'u' },
          { name: 'brochure.pdf', path: 'mounts/primary/Offers/brochure.pdf', type: 'file', ext: '.pdf' }
        ]
      },
      { name: 'logo.png', path: 'mounts/primary/logo.png', type: 'file', ext: '.png' }
    ];

    const nav = icmToNav(withFiles);

    expect(nav).toHaveLength(1); // the top-level file leaf is dropped
    expect(nav[0].children).toHaveLength(1); // the nested one too
    expect(nav[0].children?.[0].label).toBe('Founder');
  });
});

describe('encodePath', () => {
  it('encodes segments but keeps separators', () => {
    expect(encodePath('A B/C&D.md')).toBe('A%20B/C%26D.md');
  });

  // A2-T5b: an external mount's node `path` is an ABSOLUTE physical path
  // (see `Valea.ICM.tree/0`'s moduledoc), so `encodePath` sees a leading
  // empty segment (from the leading "/"). Verified against SvelteKit's own
  // `[...path]` rest-param route regex (`^/knowledge(?:/([^]*))?/?$`) that
  // `/knowledge/` + this encoded value round-trips through
  // decode_pathname -> route match -> decodeURIComponent back to the exact
  // original absolute path — this is the evidence behind wiring external
  // rows as clickable rather than leaving them inert (binding semantic 6).
  it('round-trips an absolute external path through the /knowledge/[...path] route shape', () => {
    const abs = '/Users/dev/ext mount/Offers/X.md';
    const href = `/knowledge/${encodePath(abs)}`;
    expect(href).toBe('/knowledge//Users/dev/ext%20mount/Offers/X.md');

    // Mirrors SvelteKit's route regex for `/knowledge/[...path]` (a rest
    // param consumes exactly ONE of the two consecutive slashes, capturing
    // the rest — including the external path's own leading "/" — intact).
    const routePattern = /^\/knowledge(?:\/([^]*))?\/?$/;
    const match = routePattern.exec(href);
    const captured = match?.[1] ?? null;
    expect(captured).toBe('/Users/dev/ext%20mount/Offers/X.md');

    // Our route component's own per-segment decode (split '/', decode each,
    // rejoin) reconstructs the exact original absolute path.
    const decoded = (captured ?? '')
      .split('/')
      .map((segment) => decodeURIComponent(segment))
      .join('/');
    expect(decoded).toBe(abs);
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
