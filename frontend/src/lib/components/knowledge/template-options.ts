/**
 * Pure logic for NewEntryDialog's "Start from" template select (Task C10).
 * Templates live in a mount's own `Templates/` folder — a normal top-level
 * folder in that mount's `icm_tree` (see `Valea.ICM.build_tree/2` and the
 * C5 acceptance tests), holding ordinary `.md` pages that
 * `createIcmPageFromTemplate` instantiates. That RPC requires the template
 * and the new page to live in the SAME mount (see its own moduledoc), so
 * this only ever offers templates from the mount that owns `parentPath`.
 */

import type { MountGroup } from '$lib/stores/icm.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type TemplateOption = { label: string; path: string };

/**
 * Finds the `MountGroup` that owns `parentPath` — a prefix match on
 * `rootRel`, true either at the mount's own root or for a folder nested
 * under it (the `/` boundary keeps `"mounts/primary2"` from falsely
 * matching a `"mounts/primary"` group). Handles an embedded mount's
 * workspace-relative `rootRel` (`"mounts/primary"`) and an external mount's
 * absolute one (`"/Users/dev/ext-mount"`, A2-T5b) identically: both are
 * plain string prefixes of `parentPath` in their own vocabulary.
 */
function ownerGroup(groups: MountGroup[], parentPath: string): MountGroup | undefined {
  return groups.find((g) => parentPath === g.rootRel || parentPath.startsWith(`${g.rootRel}/`));
}

/**
 * Options for the "Start from" select — one per `.md` page directly inside
 * the owning mount's `Templates/` folder, in tree order (already
 * name-sorted by the backend — see `build_tree/2`'s `Enum.sort_by`). Empty
 * when `parentPath` doesn't resolve to a known mount, that mount has no
 * `Templates/` folder, or the folder holds no pages (only subfolders, or
 * nothing at all).
 */
export function templateOptions(groups: MountGroup[], parentPath: string): TemplateOption[] {
  const group = ownerGroup(groups, parentPath);
  if (!group) return [];

  const templatesFolder = group.tree.find((n) => n.type === 'folder' && n.name === 'Templates');
  if (!templatesFolder || templatesFolder.type !== 'folder') return [];

  return (templatesFolder.children ?? [])
    .filter((n): n is IcmNode & { type: 'page' } => n.type === 'page')
    .map((n) => ({ label: n.name, path: n.path }));
}
