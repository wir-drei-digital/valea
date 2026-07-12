import { describe, expect, it } from 'vitest';
import { buildMountsDisplay, classifyMounts, degradedChipLabel, isExternalRootRel } from './mount-sections';
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { MountSummary } from '$lib/stores/mounts.svelte';
import type { IcmNode } from '$lib/shell/nav';

const primaryNode: IcmNode = {
  name: 'Clients',
  path: 'mounts/primary/Clients',
  type: 'folder',
  pageCount: 2,
  children: []
};
const clientsNode: IcmNode = {
  name: 'Contracts',
  path: 'mounts/clients/Contracts',
  type: 'folder',
  pageCount: 1,
  children: []
};

const primaryGroup: MountGroup = { mount: 'primary', title: 'Primary', rootRel: 'mounts/primary', tree: [primaryNode] };
const clientsGroup: MountGroup = { mount: 'clients', title: 'Clients', rootRel: 'mounts/clients', tree: [clientsNode] };

const primarySummary: MountSummary = {
  name: 'primary',
  title: 'Primary',
  description: 'The default mount',
  relRoot: 'mounts/primary',
  enabled: true,
  degraded: null
};
const clientsSummary: MountSummary = {
  name: 'clients',
  title: 'Clients',
  description: 'Client-facing docs',
  relRoot: 'mounts/clients',
  enabled: true,
  degraded: null
};

describe('buildMountsDisplay', () => {
  it('collapses to the single mount\'s tree at the top level when there is exactly one enabled mount', () => {
    const display = buildMountsDisplay([primaryGroup], [primarySummary]);
    expect(display).toEqual({ collapsed: true, tree: [primaryNode], rootRel: 'mounts/primary' });
  });

  it('collapses to an empty tree with an empty rootRel when there are zero enabled mounts', () => {
    const display = buildMountsDisplay([], []);
    expect(display).toEqual({ collapsed: true, tree: [], rootRel: '' });
  });

  it('splits into one section per mount, in backend order, once two or more mounts are enabled', () => {
    const display = buildMountsDisplay([primaryGroup, clientsGroup], [primarySummary, clientsSummary]);
    expect(display).toEqual({
      collapsed: false,
      sections: [
        {
          mount: 'primary',
          title: 'Primary',
          description: 'The default mount',
          rootRel: 'mounts/primary',
          tree: [primaryNode]
        },
        {
          mount: 'clients',
          title: 'Clients',
          description: 'Client-facing docs',
          rootRel: 'mounts/clients',
          tree: [clientsNode]
        }
      ]
    });
  });

  it('passes an EXTERNAL mount group through with its absolute rootRel, alongside an embedded section (A2-T5b)', () => {
    const extNode: IcmNode = {
      name: 'Offers',
      path: '/Users/dev/ext-mount/Offers',
      type: 'folder',
      pageCount: 1,
      children: []
    };
    const extGroup: MountGroup = { mount: 'ext', title: 'Ext', rootRel: '/Users/dev/ext-mount', tree: [extNode] };
    const extSummary: MountSummary = {
      name: 'ext',
      title: 'Ext',
      description: 'By-reference client folder',
      relRoot: '/Users/dev/ext-mount',
      enabled: true,
      degraded: null
    };

    const display = buildMountsDisplay([primaryGroup, extGroup], [primarySummary, extSummary]);
    expect(display.collapsed).toBe(false);
    if (!display.collapsed) {
      const extSection = display.sections.find((s) => s.mount === 'ext');
      expect(extSection).toEqual({
        mount: 'ext',
        title: 'Ext',
        description: 'By-reference client folder',
        rootRel: '/Users/dev/ext-mount',
        tree: [extNode]
      });
    }
  });

  it('joins each section\'s description by mount NAME, not title', () => {
    const renamedSummary: MountSummary = { ...clientsSummary, name: 'clients', title: 'Renamed Display Title' };
    const display = buildMountsDisplay([primaryGroup, clientsGroup], [primarySummary, renamedSummary]);
    expect(display.collapsed).toBe(false);
    if (!display.collapsed) {
      // The section's own `title` still comes from the MountGroup (the tree's own title), not the summary.
      expect(display.sections[1].title).toBe('Clients');
      expect(display.sections[1].description).toBe('Client-facing docs');
    }
  });

  it('defaults a section\'s description to "" when no matching MountSummary is found (a transient refetch-ordering gap)', () => {
    const display = buildMountsDisplay([primaryGroup, clientsGroup], [primarySummary]);
    expect(display.collapsed).toBe(false);
    if (!display.collapsed) {
      expect(display.sections[1].description).toBe('');
    }
  });
});

describe('classifyMounts', () => {
  const deactivated: MountSummary = {
    name: 'archive',
    title: 'Archive',
    description: 'Old client work',
    relRoot: 'mounts/archive',
    enabled: false,
    degraded: null
  };
  const degradedButEnabled: MountSummary = {
    name: 'broken',
    title: 'broken',
    description: '',
    relRoot: 'mounts/broken',
    enabled: true,
    degraded: 'icm.yaml is missing'
  };
  const degradedAndDisabled: MountSummary = {
    name: 'broken2',
    title: 'broken2',
    description: '',
    relRoot: 'mounts/broken2',
    enabled: false,
    degraded: 'invalid mount directory name'
  };

  it('buckets an enabled, non-degraded mount as active', () => {
    expect(classifyMounts([primarySummary])).toEqual({ active: [primarySummary], degraded: [], deactivated: [] });
  });

  it('buckets a disabled, non-degraded mount as deactivated', () => {
    expect(classifyMounts([deactivated])).toEqual({ active: [], degraded: [], deactivated: [deactivated] });
  });

  it('buckets ANY degraded mount as degraded, regardless of its enabled flag', () => {
    expect(classifyMounts([degradedButEnabled, degradedAndDisabled])).toEqual({
      active: [],
      degraded: [degradedButEnabled, degradedAndDisabled],
      deactivated: []
    });
  });

  it('splits a mixed catalog into all three buckets, preserving relative order within each', () => {
    const result = classifyMounts([primarySummary, deactivated, degradedButEnabled, clientsSummary]);
    expect(result).toEqual({
      active: [primarySummary, clientsSummary],
      degraded: [degradedButEnabled],
      deactivated: [deactivated]
    });
  });

  it('returns empty buckets for an empty catalog', () => {
    expect(classifyMounts([])).toEqual({ active: [], degraded: [], deactivated: [] });
  });
});

describe('isExternalRootRel (A2-T5b)', () => {
  it('is false for an embedded mount\'s workspace-relative rootRel', () => {
    expect(isExternalRootRel('mounts/primary')).toBe(false);
  });

  it('is false for the collapsed zero-mounts empty rootRel', () => {
    expect(isExternalRootRel('')).toBe(false);
  });

  it('is true for an external mount\'s absolute physical rootRel', () => {
    expect(isExternalRootRel('/Users/dev/ext-mount')).toBe(true);
  });
});

describe('degradedChipLabel', () => {
  it('prefixes the reason with "Degraded — "', () => {
    expect(degradedChipLabel({ degraded: 'icm.yaml is missing' })).toBe('Degraded — icm.yaml is missing');
  });

  it('falls back to a generic reason when degraded is null (defensive — callers only invoke this for a degraded mount)', () => {
    expect(degradedChipLabel({ degraded: null })).toBe('Degraded — unknown reason');
  });
});
