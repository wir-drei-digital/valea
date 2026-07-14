import { describe, expect, it } from 'vitest';
import { templateOptions } from './template-options';
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

const clientTemplate: IcmNode = {
  name: 'Client Intro',
  path: 'Templates/Client Intro.md',
  mountKey: 'primary',
  type: 'page'
};
const reportTemplate: IcmNode = { name: 'Report', path: 'Templates/Report.md', mountKey: 'primary', type: 'page' };
const templatesFolder: IcmNode = {
  name: 'Templates',
  path: 'Templates',
  mountKey: 'primary',
  type: 'folder',
  pageCount: 2,
  children: [clientTemplate, reportTemplate]
};
const offersFolder: IcmNode = {
  name: 'Offers',
  path: 'Offers',
  mountKey: 'primary',
  type: 'folder',
  pageCount: 0,
  children: []
};

const primaryGroup: MountGroup = {
  mount: 'primary',
  title: 'Primary',
  tree: [offersFolder, templatesFolder]
};

const secondaryGroup: MountGroup = {
  mount: 'secondary',
  title: 'Secondary',
  tree: [{ name: 'Notes', path: 'Notes', mountKey: 'secondary', type: 'folder', pageCount: 0, children: [] }]
};

describe('templateOptions', () => {
  it('returns one option per page in the owning mount\'s Templates/ folder, in tree order', () => {
    expect(templateOptions([primaryGroup], 'primary')).toEqual([
      { label: 'Client Intro', path: 'Templates/Client Intro.md' },
      { label: 'Report', path: 'Templates/Report.md' }
    ]);
  });

  it('returns [] for a mount with no Templates/ folder at all', () => {
    expect(templateOptions([secondaryGroup], 'secondary')).toEqual([]);
  });

  it('returns [] when the Templates/ folder exists but holds no pages', () => {
    const emptyTemplates: IcmNode = {
      name: 'Templates',
      path: 'Templates',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 0,
      children: []
    };
    const group: MountGroup = { mount: 'primary', title: 'Primary', tree: [emptyTemplates] };
    expect(templateOptions([group], 'primary')).toEqual([]);
  });

  it('excludes non-page children (subfolders) of the Templates/ folder', () => {
    const subfolder: IcmNode = {
      name: 'Archived',
      path: 'Templates/Archived',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 0,
      children: []
    };
    const mixedTemplates: IcmNode = {
      name: 'Templates',
      path: 'Templates',
      mountKey: 'primary',
      type: 'folder',
      pageCount: 1,
      children: [subfolder, reportTemplate]
    };
    const group: MountGroup = { mount: 'primary', title: 'Primary', tree: [mixedTemplates] };
    expect(templateOptions([group], 'primary')).toEqual([{ label: 'Report', path: 'Templates/Report.md' }]);
  });

  it('returns [] when mountKey does not resolve to any known group', () => {
    expect(templateOptions([primaryGroup], 'unknown')).toEqual([]);
  });

  it('returns [] for an empty groups list', () => {
    expect(templateOptions([], 'primary')).toEqual([]);
  });

  it('does not let a mount with a longer, similarly-prefixed key falsely match (boundary correctness)', () => {
    const primary2Template: IcmNode = {
      name: 'Other',
      path: 'Templates/Other.md',
      mountKey: 'primary2',
      type: 'page'
    };
    const primary2Group: MountGroup = {
      mount: 'primary2',
      title: 'Primary2',
      tree: [
        {
          name: 'Templates',
          path: 'Templates',
          mountKey: 'primary2',
          type: 'folder',
          pageCount: 1,
          children: [primary2Template]
        }
      ]
    };
    // "primary2" must resolve to the primary2 group by exact key match, not
    // fall through to "primary" via any prefix-based logic.
    expect(templateOptions([primaryGroup, primary2Group], 'primary2')).toEqual([
      { label: 'Other', path: 'Templates/Other.md' }
    ]);
  });
});
