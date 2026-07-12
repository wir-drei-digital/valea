import { describe, expect, it } from 'vitest';
import {
  buildMountsDisplay,
  classifyMounts,
  degradedChipLabel,
  isExternalRootRel,
  isExternalMount,
  normalizeMountsDoctorChecks
} from './mount-sections';
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
  root: '/Users/dev/workspace/mounts/primary',
  enabled: true,
  degraded: null
};
const clientsSummary: MountSummary = {
  name: 'clients',
  title: 'Clients',
  description: 'Client-facing docs',
  relRoot: 'mounts/clients',
  root: '/Users/dev/workspace/mounts/clients',
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
    // `relRoot: null` (not the absolute path) — A2-T8 gave `list_mounts` a
    // SEPARATE `root` field for an external mount's real location; `relRoot`
    // stays `null` for one (`Valea.Mounts.mount()`'s own convention). This
    // fixture predates that split; corrected here per the A2-T9 brief's
    // "verify + extend tests if gaps" instruction for the deactivated/
    // degraded groups' external handling.
    const extSummary: MountSummary = {
      name: 'ext',
      title: 'Ext',
      description: 'By-reference client folder',
      relRoot: null,
      root: '/Users/dev/ext-mount',
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
    root: '/Users/dev/workspace/mounts/archive',
    enabled: false,
    degraded: null
  };
  const degradedButEnabled: MountSummary = {
    name: 'broken',
    title: 'broken',
    description: '',
    relRoot: 'mounts/broken',
    root: '/Users/dev/workspace/mounts/broken',
    enabled: true,
    degraded: 'icm.yaml is missing'
  };
  const degradedAndDisabled: MountSummary = {
    name: 'broken2',
    title: 'broken2',
    description: '',
    relRoot: 'mounts/broken2',
    root: '/Users/dev/workspace/mounts/broken2',
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

// A2-T9: tells an EXTERNAL `list_mounts` row (`relRoot: null`, see
// `MountSummary`'s doc comment) apart from an embedded one — used by the
// deactivated/degraded groups (and the mount detail rows) to decide when to
// show `mount.root` as the real location and offer "Unmount".
describe('isExternalMount', () => {
  it('is true when relRoot is null (external, by-reference)', () => {
    expect(isExternalMount({ relRoot: null })).toBe(true);
  });

  it('is false when relRoot is a workspace-relative string (embedded)', () => {
    expect(isExternalMount({ relRoot: 'mounts/primary' })).toBe(false);
  });
});

// A2-T9: `mounts_doctor`'s `checks` field is the SAME unconstrained-`:map`
// passthrough shape `mail_doctor` uses (`Valea.Api.Mounts`'s moduledoc) —
// `{id, label, status, detail, remedy}` — so this mirrors
// `mail-shapes.ts`'s `normalizeMailDoctorChecks` defensive narrowing
// exactly (an entry with no `id` is dropped rather than rendered as a
// mystery row).
describe('normalizeMountsDoctorChecks', () => {
  it('narrows a well-formed checks array', () => {
    const raw = [
      { id: 'manifest_ok:primary', label: 'primary: manifest', status: 'ok', detail: 'icm.yaml loads.', remedy: null },
      {
        id: 'ref_resolves:client-notes',
        label: 'client-notes: reference resolves',
        status: 'failed',
        detail: 'folder not found at ~/Client Notes',
        remedy: 'Check this mount\'s reference in Settings.'
      }
    ];
    expect(normalizeMountsDoctorChecks(raw)).toEqual([
      { id: 'manifest_ok:primary', label: 'primary: manifest', status: 'ok', detail: 'icm.yaml loads.', remedy: null },
      {
        id: 'ref_resolves:client-notes',
        label: 'client-notes: reference resolves',
        status: 'failed',
        detail: 'folder not found at ~/Client Notes',
        remedy: 'Check this mount\'s reference in Settings.'
      }
    ]);
  });

  it('defaults a missing label to the id, missing status to "unknown", missing detail to "", missing remedy to null', () => {
    expect(normalizeMountsDoctorChecks([{ id: 'watcher_live:ext' }])).toEqual([
      { id: 'watcher_live:ext', label: 'watcher_live:ext', status: 'unknown', detail: '', remedy: null }
    ]);
  });

  it('drops an entry with no id rather than rendering a mystery row', () => {
    expect(normalizeMountsDoctorChecks([{ label: 'no id here', status: 'ok' }])).toEqual([]);
  });

  it('returns an empty array for a non-array payload', () => {
    expect(normalizeMountsDoctorChecks(null)).toEqual([]);
    expect(normalizeMountsDoctorChecks(undefined)).toEqual([]);
    expect(normalizeMountsDoctorChecks('not an array')).toEqual([]);
  });
});
