import { describe, expect, it } from 'vitest';
import { templateGroups } from './template-options';
import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

function page(name: string, path: string, mountKey = 'icm'): IcmNode {
  return { name, path, mountKey, type: 'page' };
}

function folder(name: string, path: string, children: IcmNode[], mountKey = 'icm'): IcmNode {
  return { name, path, mountKey, type: 'folder', pageCount: children.length, children };
}

describe('templateGroups', () => {
  it('finds a top-level Templates folder (case-insensitive)', () => {
    const templatesFolder = folder('Templates', 'Templates', [
      page('Client', 'Templates/Client.md'),
      page('Decision', 'Templates/Decision.md')
    ]);
    const group: MountGroup = { mount: 'icm', title: 'ICM', tree: [templatesFolder] };

    expect(templateGroups([group], 'icm')).toEqual([
      {
        label: 'Templates',
        options: [
          { label: 'Client', path: 'Templates/Client.md' },
          { label: 'Decision', path: 'Templates/Decision.md' }
        ]
      }
    ]);
  });

  it('finds nested templates/ folders at any depth, case-insensitively, in tree order', () => {
    const kitaTemplates = folder('templates', 'clients/kita/templates', [
      page('Prep', 'clients/kita/templates/Prep.md')
    ]);
    const kita = folder('kita', 'clients/kita', [kitaTemplates]);
    const clients = folder('clients', 'clients', [kita]);

    const opsTemplates = folder('TEMPLATES', 'ops/TEMPLATES', [page('Runbook', 'ops/TEMPLATES/Runbook.md')]);
    const ops = folder('ops', 'ops', [opsTemplates]);

    const group: MountGroup = { mount: 'icm', title: 'ICM', tree: [clients, ops] };

    const result = templateGroups([group], 'icm');
    expect(result.map((g) => g.label)).toEqual(['clients/kita/templates', 'ops/TEMPLATES']);
    expect(result[0].options).toEqual([{ label: 'Prep', path: 'clients/kita/templates/Prep.md' }]);
    expect(result[1].options).toEqual([{ label: 'Runbook', path: 'ops/TEMPLATES/Runbook.md' }]);
  });

  it('only direct .md pages count; a subfolder inside a templates dir is not flattened into it', () => {
    const sub = folder('sub', 'Templates/sub', [page('B', 'Templates/sub/B.md')]);
    const templatesFolder = folder('Templates', 'Templates', [page('A', 'Templates/A.md'), sub]);
    const group: MountGroup = { mount: 'icm', title: 'ICM', tree: [templatesFolder] };

    const result = templateGroups([group], 'icm');
    expect(result).toHaveLength(1);
    expect(result[0].options.map((o) => o.label)).toEqual(['A']);
  });

  it('a nested templates/ folder found inside another templates/ folder becomes its own group', () => {
    // Recursion must not stop just because a folder already matched — the
    // discovery walk keeps descending into every matched folder's children too.
    const nested = folder('templates', 'Templates/templates', [page('Nested', 'Templates/templates/Nested.md')]);
    const templatesFolder = folder('Templates', 'Templates', [page('A', 'Templates/A.md'), nested]);
    const group: MountGroup = { mount: 'icm', title: 'ICM', tree: [templatesFolder] };

    const result = templateGroups([group], 'icm');
    expect(result.map((g) => g.label)).toEqual(['Templates', 'Templates/templates']);
  });

  it('drops empty templates folders, and yields [] for an unknown mount or an empty groups list', () => {
    const emptyTemplates = folder('Templates', 'Templates', []);
    const groupWithEmpty: MountGroup = { mount: 'icm', title: 'ICM', tree: [emptyTemplates] };
    const templatesFolder = folder('Templates', 'Templates', [page('Client', 'Templates/Client.md')]);
    const group: MountGroup = { mount: 'icm', title: 'ICM', tree: [templatesFolder] };

    expect(templateGroups([groupWithEmpty], 'icm')).toEqual([]);
    expect(templateGroups([group], 'nope')).toEqual([]);
    expect(templateGroups([], 'icm')).toEqual([]);
  });

  it('does not let a mount with a longer, similarly-prefixed key falsely match (boundary correctness)', () => {
    const primaryTemplates = folder('Templates', 'Templates', [page('Client', 'Templates/Client.md')], 'primary');
    const primaryGroup: MountGroup = { mount: 'primary', title: 'Primary', tree: [primaryTemplates] };
    const primary2Templates = folder('Templates', 'Templates', [page('Other', 'Templates/Other.md')], 'primary2');
    const primary2Group: MountGroup = { mount: 'primary2', title: 'Primary2', tree: [primary2Templates] };

    // "primary2" must resolve to the primary2 group by exact key match, not
    // fall through to "primary" via any prefix-based logic.
    expect(templateGroups([primaryGroup, primary2Group], 'primary2')).toEqual([
      { label: 'Templates', options: [{ label: 'Other', path: 'Templates/Other.md' }] }
    ]);
  });
});
