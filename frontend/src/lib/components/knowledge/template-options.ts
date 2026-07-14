/**
 * Pure logic for NewEntryDialog's "Start from" template select (Task C10).
 * Templates live in a mount's own `Templates/` folder — a normal top-level
 * folder in that mount's `icm_tree` (see `Valea.ICM.build_tree/2` and the
 * C5 acceptance tests), holding ordinary `.md` pages that
 * `createIcmPageFromTemplate` instantiates. That RPC requires the template
 * and the new page to live in the SAME mount (see its own moduledoc), so
 * this only ever offers templates from `mountKey`'s own group.
 *
 * Task 4.2/4.3 re-key: template/page paths are ICM-relative now, so there
 * is no more `rootRel` string prefix to match `parentPath` against — the
 * owning mount is simply looked up by `mountKey` directly (the same key the
 * caller already has, since a create action always names its target mount
 * explicitly).
 */

import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type TemplateOption = { label: string; path: string };

/**
 * Options for the "Start from" select — one per `.md` page directly inside
 * `mountKey`'s own `Templates/` folder, in tree order (already
 * name-sorted by the backend — see `build_tree/2`'s `Enum.sort_by`). Empty
 * when `mountKey` doesn't name a currently-loaded group, that mount has no
 * `Templates/` folder, or the folder holds no pages (only subfolders, or
 * nothing at all).
 */
export function templateOptions(groups: MountGroup[], mountKey: string): TemplateOption[] {
  const group = groups.find((g) => g.mount === mountKey);
  if (!group) return [];

  const templatesFolder = group.tree.find((n) => n.type === 'folder' && n.name === 'Templates');
  if (!templatesFolder || templatesFolder.type !== 'folder') return [];

  return (templatesFolder.children ?? [])
    .filter((n): n is IcmNode & { type: 'page' } => n.type === 'page')
    .map((n) => ({ label: n.name, path: n.path }));
}
