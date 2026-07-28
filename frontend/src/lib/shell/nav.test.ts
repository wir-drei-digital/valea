import { describe, expect, it } from 'vitest';
import { icmToNav, encodePath, flattenMountGroups, type IcmNode } from './nav';

const tree: IcmNode[] = [
  {
    name: 'Tone & Voice',
    path: 'Tone & Voice',
    mountKey: 'primary',
    type: 'folder',
    pageCount: 2,
    children: [
      {
        name: 'Email Tone Guide',
        path: 'Tone & Voice/Email Tone Guide.md',
        mountKey: 'primary',
        type: 'page',
        uri: 'icm://Tone & Voice/Email Tone Guide.md'
      }
    ]
  }
];

describe('icmToNav', () => {
  it('maps folders with counts and encoded hrefs, prefixed with the mount key (task 4.3)', () => {
    const nav = icmToNav(tree);
    expect(nav[0].label).toBe('Tone & Voice');
    expect(nav[0].count).toBe(2);
    expect(nav[0].href).toBe('/knowledge/primary/Tone%20%26%20Voice');
    expect(nav[0].children?.[0].href).toBe('/knowledge/primary/Tone%20%26%20Voice/Email%20Tone%20Guide.md');
  });

  // Side-panes pass: file leaves are navigable now (FileView renders the
  // non-.md formats), so they get an href and carry their `ext` through for
  // the tree row's format badge — the old "emitted nowhere" special case is
  // gone.
  it('emits file leaves with an href and their ext, at every depth', () => {
    const withFiles: IcmNode[] = [
      {
        name: 'Offers',
        path: 'Offers',
        mountKey: 'primary',
        type: 'folder',
        pageCount: 1,
        children: [
          { name: 'Founder', path: 'Offers/Founder.md', mountKey: 'primary', type: 'page', uri: 'u' },
          { name: 'brochure.pdf', path: 'Offers/brochure.pdf', mountKey: 'primary', type: 'file', ext: '.pdf' }
        ]
      },
      { name: 'logo.png', path: 'logo.png', mountKey: 'primary', type: 'file', ext: '.png' }
    ];

    const nav = icmToNav(withFiles);

    expect(nav).toHaveLength(2);
    expect(nav[1]).toMatchObject({
      label: 'logo.png',
      href: '/knowledge/primary/logo.png',
      path: 'logo.png',
      mountKey: 'primary',
      ext: '.png'
    });
    // A file leaf is a LEAF: no `children`, so `IcmTree` renders it as a row
    // rather than an expandable folder.
    expect(nav[1].children).toBeUndefined();

    expect(nav[0].children).toHaveLength(2);
    expect(nav[0].children?.[1]).toMatchObject({
      label: 'brochure.pdf',
      href: '/knowledge/primary/Offers/brochure.pdf',
      ext: '.pdf'
    });
    // Pages still carry no `ext` — only file leaves do.
    expect(nav[0].children?.[0].ext).toBeUndefined();
  });

  // `isFile` — NOT `ext` — is what marks a leaf as a non-.md file. An
  // extension-less regular file (LICENSE, Makefile, a dotfile) arrives with
  // `ext: ''` from `Path.extname/1`, so any truthiness check on `ext` would
  // misclassify it as a page and hand it the page-shaped EntryMenu
  // (rename would append `.md`). See IcmTree's leaf branch.
  it('marks every file leaf with isFile, including extension-less ones', () => {
    const nodes: IcmNode[] = [
      { name: 'Founder', path: 'Founder.md', mountKey: 'primary', type: 'page', uri: 'u' },
      { name: 'brochure.pdf', path: 'brochure.pdf', mountKey: 'primary', type: 'file', ext: '.pdf' },
      { name: 'LICENSE', path: 'LICENSE', mountKey: 'primary', type: 'file', ext: '' },
      { name: 'Assets', path: 'Assets', mountKey: 'primary', type: 'folder', children: [] }
    ];

    const nav = icmToNav(nodes);

    expect(nav.map((n) => n.isFile)).toEqual([undefined, true, true, undefined]);
    expect(nav[2].ext).toBe('');
  });

  it('a node from a different mount gets that mount\'s own href prefix', () => {
    const nodes: IcmNode[] = [
      { name: 'A', path: 'A.md', mountKey: 'primary', type: 'page', uri: 'u' },
      { name: 'B', path: 'B.md', mountKey: 'clients', type: 'page', uri: 'u' }
    ];

    const nav = icmToNav(nodes);
    expect(nav[0].href).toBe('/knowledge/primary/A.md');
    expect(nav[1].href).toBe('/knowledge/clients/B.md');
  });
});

describe('encodePath', () => {
  it('encodes segments but keeps separators', () => {
    expect(encodePath('A B/C&D.md')).toBe('A%20B/C%26D.md');
  });
});

// Replaces the deleted `IcmStore.nodes` back-compat getter (A-T15) — every
// consumer that just needs a single flat search/nav list (not a per-mount
// grouped display) flattens `icmStore.groups` through this instead. Each
// node carries its own `mountKey` (task 4.3), so flattening across mounts
// never loses which ICM a node belongs to.
describe('flattenMountGroups', () => {
  const nodeA: IcmNode = { name: 'A', path: 'A', mountKey: 'primary', type: 'page', uri: 'icm://A' };
  const nodeB: IcmNode = { name: 'B', path: 'B', mountKey: 'clients', type: 'page', uri: 'icm://B' };

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
