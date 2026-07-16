/**
 * Recursive template discovery for NewEntryDialog's "Start from" select
 * (Spec D §D2): any folder named `templates` (case-insensitive) at ANY
 * depth in the selected mount's tree contributes a group of its direct
 * `.md` pages. The backend RPC (`createIcmPageFromTemplate`) never had a
 * location restriction — this discovery layer was the only thing pinning
 * templates to one top-level folder.
 *
 * Task 4.2/4.3 re-key: template/page paths are ICM-relative, so there is no
 * `rootRel` string prefix to match `parentPath` against — the owning mount
 * is simply looked up by `mountKey` directly (the same key the caller
 * already has, since a create action always names its target mount
 * explicitly). That RPC also requires the template and the new page to
 * live in the SAME mount (see its own moduledoc), so this only ever offers
 * templates from `mountKey`'s own group.
 */

import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type TemplateOption = { label: string; path: string };
export type TemplateGroup = { label: string; options: TemplateOption[] };

/**
 * One group per folder named `templates` (case-insensitive) found anywhere
 * in `mountKey`'s tree, `label` set to that folder's own tree path. Each
 * group's `options` are the `.md` pages directly inside the folder, in
 * tree order (already name-sorted by the backend — see `build_tree/2`'s
 * `Enum.sort_by`); subfolders inside a `templates/` folder are not
 * flattened into it, though a nested `templates/`-named folder within one
 * still gets discovered and reported as its own group. Groups with no
 * pages are dropped. Empty when `mountKey` doesn't name a
 * currently-loaded group.
 */
export function templateGroups(groups: MountGroup[], mountKey: string): TemplateGroup[] {
  const group = groups.find((g) => g.mount === mountKey);
  if (!group) return [];

  // `path` and `children` are common IcmNode fields (not folder-specific),
  // so this list stays plain `IcmNode[]` rather than an `& { type: 'folder' }`
  // intersection — narrowing `node.type` through a `.push` into a
  // separately-declared array doesn't survive TS's control-flow analysis.
  const folders: IcmNode[] = [];
  const walk = (nodes: IcmNode[] | undefined) => {
    for (const node of nodes ?? []) {
      if (node.type !== 'folder') continue;
      if (node.name.toLowerCase() === 'templates') folders.push(node);
      walk(node.children);
    }
  };
  walk(group.tree);

  return folders
    .map((folder) => ({
      label: folder.path,
      options: (folder.children ?? [])
        .filter((n): n is IcmNode & { type: 'page' } => n.type === 'page')
        .map((n) => ({ label: n.name, path: n.path }))
    }))
    .filter((g) => g.options.length > 0);
}
