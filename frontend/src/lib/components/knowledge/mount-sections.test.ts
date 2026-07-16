import { describe, expect, it } from 'vitest';
import {
  adoptFailureBannerText,
  buildMountsDisplay,
  classifyMounts,
  degradedChipLabel,
  normalizeMountsDoctorChecks
} from './mount-sections';
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { MountSummary } from '$lib/stores/mounts.svelte';
import type { IcmNode } from '$lib/shell/nav';

const primaryNode: IcmNode = {
  name: 'Clients',
  path: 'Clients',
  mountKey: 'primary',
  type: 'folder',
  pageCount: 2,
  children: []
};
const clientsNode: IcmNode = {
  name: 'Contracts',
  path: 'Contracts',
  mountKey: 'clients',
  type: 'folder',
  pageCount: 1,
  children: []
};

const primaryGroup: MountGroup = { mount: 'primary', title: 'Primary', tree: [primaryNode] };
const clientsGroup: MountGroup = { mount: 'clients', title: 'Clients', tree: [clientsNode] };

const primarySummary: MountSummary = {
  mountKey: 'primary',
  id: '11111111-1111-1111-1111-111111111111',
  name: 'Primary',
  description: 'The default mount',
  root: '/Users/dev/workspace/mounts/primary',
  enabled: true,
  degraded: null
};
const clientsSummary: MountSummary = {
  mountKey: 'clients',
  id: '22222222-2222-2222-2222-222222222222',
  name: 'Clients',
  description: 'Client-facing docs',
  root: '/Users/dev/workspace/mounts/clients',
  enabled: true,
  degraded: null
};

describe('buildMountsDisplay', () => {
  it('collapses to the single mount\'s tree at the top level when there is exactly one enabled mount', () => {
    const display = buildMountsDisplay([primaryGroup], [primarySummary]);
    expect(display).toEqual({ collapsed: true, mount: 'primary', tree: [primaryNode] });
  });

  it('collapses to an empty tree with an empty mount key when there are zero enabled mounts', () => {
    const display = buildMountsDisplay([], []);
    expect(display).toEqual({ collapsed: true, mount: '', tree: [] });
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
          root: '/Users/dev/workspace/mounts/primary',
          tree: [primaryNode]
        },
        {
          mount: 'clients',
          title: 'Clients',
          description: 'Client-facing docs',
          root: '/Users/dev/workspace/mounts/clients',
          tree: [clientsNode]
        }
      ]
    });
  });

  it('joins each section\'s description/root by mount KEY, not display name (task 3.4)', () => {
    const renamedSummary: MountSummary = { ...clientsSummary, mountKey: 'clients', name: 'Renamed Display Name' };
    const display = buildMountsDisplay([primaryGroup, clientsGroup], [primarySummary, renamedSummary]);
    expect(display.collapsed).toBe(false);
    if (!display.collapsed) {
      // The section's own `title` still comes from the MountGroup (the tree's own title), not the summary.
      expect(display.sections[1].title).toBe('Clients');
      expect(display.sections[1].description).toBe('Client-facing docs');
      expect(display.sections[1].root).toBe('/Users/dev/workspace/mounts/clients');
    }
  });

  it('defaults a section\'s description/root to "" when no matching MountSummary is found (a transient refetch-ordering gap)', () => {
    const display = buildMountsDisplay([primaryGroup, clientsGroup], [primarySummary]);
    expect(display.collapsed).toBe(false);
    if (!display.collapsed) {
      expect(display.sections[1].description).toBe('');
      expect(display.sections[1].root).toBe('');
    }
  });
});

describe('classifyMounts', () => {
  const deactivated: MountSummary = {
    mountKey: 'archive',
    id: '44444444-4444-4444-4444-444444444444',
    name: 'Archive',
    description: 'Old client work',
    root: '/Users/dev/workspace/mounts/archive',
    enabled: false,
    degraded: null
  };
  const degradedButEnabled: MountSummary = {
    mountKey: 'broken',
    id: null,
    name: 'broken',
    description: '',
    root: '/Users/dev/workspace/mounts/broken',
    enabled: true,
    degraded: 'icm.yaml is missing'
  };
  const degradedAndDisabled: MountSummary = {
    mountKey: 'broken2',
    id: null,
    name: 'broken2',
    description: '',
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

describe('degradedChipLabel', () => {
  it('prefixes the reason with "Degraded — "', () => {
    expect(degradedChipLabel({ degraded: 'icm.yaml is missing' })).toBe('Degraded — icm.yaml is missing');
  });

  it('falls back to a generic reason when degraded is null (defensive — callers only invoke this for a degraded mount)', () => {
    expect(degradedChipLabel({ degraded: null })).toBe('Degraded — unknown reason');
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
      {
        id: 'manifest_format2:primary',
        label: 'primary: manifest',
        status: 'ok',
        detail: 'icm.yaml loads.',
        remedy: null
      },
      {
        id: 'path_resolves:client-notes',
        label: 'client-notes: path resolves',
        status: 'failed',
        detail: 'folder not found at ~/Client Notes',
        remedy: "Check this mount's path in Settings."
      }
    ];
    expect(normalizeMountsDoctorChecks(raw)).toEqual([
      {
        id: 'manifest_format2:primary',
        label: 'primary: manifest',
        status: 'ok',
        detail: 'icm.yaml loads.',
        remedy: null
      },
      {
        id: 'path_resolves:client-notes',
        label: 'client-notes: path resolves',
        status: 'failed',
        detail: 'folder not found at ~/Client Notes',
        remedy: "Check this mount's path in Settings."
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

// Fix wave 1 (A2-T9): the exact copy of the Knowledge page's
// adoption-failure banner — rendered from `mountsStore.pendingAdoptError`
// after a declare-stage reference-adoption failure survived the
// onboarding-to-app transition. Kept as a pure function so the copy (which
// names the retry affordance) is table-testable.
describe('adoptFailureBannerText', () => {
  it('names the mount, its source ref, the mapped message, and the retry affordance', () => {
    expect(
      adoptFailureBannerText({
        name: 'Client Notes',
        ref: '/Users/mara/Documents/Client Notes',
        message: "That folder doesn't look like a knowledge module yet — it needs an icm.yaml."
      })
    ).toBe(
      'Couldn\'t mount "Client Notes" from /Users/mara/Documents/Client Notes: ' +
        "That folder doesn't look like a knowledge module yet — it needs an icm.yaml. " +
        'You can retry from "Mount a folder from elsewhere…".'
    );
  });
});
