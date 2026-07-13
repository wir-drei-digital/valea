import { describe, expect, it } from 'vitest';
import { templateOptions } from './template-options';
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

const clientTemplate: IcmNode = { name: 'Client Intro', path: 'mounts/primary/Templates/Client Intro.md', type: 'page' };
const reportTemplate: IcmNode = { name: 'Report', path: 'mounts/primary/Templates/Report.md', type: 'page' };
const templatesFolder: IcmNode = {
  name: 'Templates',
  path: 'mounts/primary/Templates',
  type: 'folder',
  pageCount: 2,
  children: [clientTemplate, reportTemplate]
};
const offersFolder: IcmNode = {
  name: 'Offers',
  path: 'mounts/primary/Offers',
  type: 'folder',
  pageCount: 0,
  children: []
};

const primaryGroup: MountGroup = {
  mount: 'primary',
  title: 'Primary',
  rootRel: 'mounts/primary',
  tree: [offersFolder, templatesFolder]
};

const secondaryGroup: MountGroup = {
  mount: 'secondary',
  title: 'Secondary',
  rootRel: 'mounts/secondary',
  tree: [{ name: 'Notes', path: 'mounts/secondary/Notes', type: 'folder', pageCount: 0, children: [] }]
};

describe('templateOptions', () => {
  it('returns one option per page in the owning mount\'s Templates/ folder, in tree order', () => {
    expect(templateOptions([primaryGroup], 'mounts/primary')).toEqual([
      { label: 'Client Intro', path: 'mounts/primary/Templates/Client Intro.md' },
      { label: 'Report', path: 'mounts/primary/Templates/Report.md' }
    ]);
  });

  it('resolves the owning mount from a folder nested under its root, not just the root itself', () => {
    expect(templateOptions([primaryGroup], 'mounts/primary/Offers')).toEqual([
      { label: 'Client Intro', path: 'mounts/primary/Templates/Client Intro.md' },
      { label: 'Report', path: 'mounts/primary/Templates/Report.md' }
    ]);
  });

  it('returns [] for a mount with no Templates/ folder at all', () => {
    expect(templateOptions([secondaryGroup], 'mounts/secondary')).toEqual([]);
  });

  it('returns [] when the Templates/ folder exists but holds no pages', () => {
    const emptyTemplates: IcmNode = { name: 'Templates', path: 'mounts/primary/Templates', type: 'folder', pageCount: 0, children: [] };
    const group: MountGroup = { mount: 'primary', title: 'Primary', rootRel: 'mounts/primary', tree: [emptyTemplates] };
    expect(templateOptions([group], 'mounts/primary')).toEqual([]);
  });

  it('excludes non-page children (subfolders) of the Templates/ folder', () => {
    const subfolder: IcmNode = { name: 'Archived', path: 'mounts/primary/Templates/Archived', type: 'folder', pageCount: 0, children: [] };
    const mixedTemplates: IcmNode = {
      name: 'Templates',
      path: 'mounts/primary/Templates',
      type: 'folder',
      pageCount: 1,
      children: [subfolder, reportTemplate]
    };
    const group: MountGroup = { mount: 'primary', title: 'Primary', rootRel: 'mounts/primary', tree: [mixedTemplates] };
    expect(templateOptions([group], 'mounts/primary')).toEqual([{ label: 'Report', path: 'mounts/primary/Templates/Report.md' }]);
  });

  it('returns [] when parentPath does not resolve to any known mount', () => {
    expect(templateOptions([primaryGroup], 'mounts/unknown')).toEqual([]);
  });

  it('returns [] for an empty groups list', () => {
    expect(templateOptions([], 'mounts/primary')).toEqual([]);
  });

  it('does not let a mount with a longer, similarly-prefixed name falsely match (boundary correctness)', () => {
    const primary2Template: IcmNode = { name: 'Other', path: 'mounts/primary2/Templates/Other.md', type: 'page' };
    const primary2Group: MountGroup = {
      mount: 'primary2',
      title: 'Primary2',
      rootRel: 'mounts/primary2',
      tree: [{ name: 'Templates', path: 'mounts/primary2/Templates', type: 'folder', pageCount: 1, children: [primary2Template] }]
    };
    // "mounts/primary2" must resolve to the primary2 group, not fall through
    // to "primary" via a naive (non-boundary) prefix match.
    expect(templateOptions([primaryGroup, primary2Group], 'mounts/primary2')).toEqual([
      { label: 'Other', path: 'mounts/primary2/Templates/Other.md' }
    ]);
  });

  it('resolves an external (by-reference) mount whose rootRel is an absolute path (A2-T5b)', () => {
    const extTemplate: IcmNode = { name: 'External Intro', path: '/Users/dev/ext-mount/Templates/External Intro.md', type: 'page' };
    const extTemplates: IcmNode = {
      name: 'Templates',
      path: '/Users/dev/ext-mount/Templates',
      type: 'folder',
      pageCount: 1,
      children: [extTemplate]
    };
    const extGroup: MountGroup = { mount: 'ext', title: 'Ext', rootRel: '/Users/dev/ext-mount', tree: [extTemplates] };
    expect(templateOptions([extGroup], '/Users/dev/ext-mount')).toEqual([
      { label: 'External Intro', path: '/Users/dev/ext-mount/Templates/External Intro.md' }
    ]);
  });
});
