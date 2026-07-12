/**
 * Pure decision logic for the mounts-aware Knowledge UI (A-T15) — how
 * `icmStore.groups` (one `MountGroup` per ENABLED, non-degraded mount — see
 * `Valea.ICM.tree/0`'s moduledoc) and `mountsStore.mounts` (every
 * discovered mount, enabled or not, degraded or not — see
 * `Valea.Mounts.list/0`) combine into what the Knowledge page renders.
 * Same "extract the logic, no component render harness" convention as
 * `today/triage-card.ts`/`mail/mail-shapes.ts`.
 */

import type { MountGroup } from '$lib/stores/icm.svelte';
import type { MountSummary } from '$lib/stores/mounts.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type MountSection = {
  mount: string;
  title: string;
  description: string;
  /** The mount's own workspace-relative root (`MountGroup.rootRel`, e.g. `"mounts/primary"`) — where this section's "New page/folder" action creates into. */
  rootRel: string;
  tree: IcmNode[];
};

/**
 * `collapsed: true` — the pre-mounts look: render `tree` directly at the
 * top level, no per-mount header. Chosen whenever there is AT MOST one
 * enabled mount (zero enabled mounts collapses to an empty `tree`, with
 * `rootRel: ''` — there's nothing to group, and nowhere to create into).
 * `collapsed: false` — two or more enabled mounts: one `MountSection`
 * (title + description header) per mount, backend order preserved.
 */
export type MountsDisplay =
  | { collapsed: true; tree: IcmNode[]; rootRel: string }
  | { collapsed: false; sections: MountSection[] };

/**
 * `groups` is `icmStore.groups` — the direct source of truth for what tree
 * data actually exists and how many mounts are effectively enabled.
 * `mounts` (`mountsStore.mounts`) supplies each section's header
 * `description`, which `MountGroup` itself doesn't carry (see
 * `Valea.Api.Mounts.to_rpc_mount/1`). Joined by mount NAME — the stable
 * identifier both `MountGroup.mount` and `MountSummary.name` share, NOT
 * `title` (the human display name, which two mounts could coincidentally
 * share). A mount present in `groups` but missing from `mounts` (a
 * transient refetch-ordering gap between the two live stores, which
 * refresh together on `mounts_changed` but aren't atomic) degrades to an
 * empty description rather than throwing.
 */
export function buildMountsDisplay(groups: MountGroup[], mounts: MountSummary[]): MountsDisplay {
  if (groups.length <= 1) {
    return { collapsed: true, tree: groups[0]?.tree ?? [], rootRel: groups[0]?.rootRel ?? '' };
  }

  const descriptionByName = new Map(mounts.map((m) => [m.name, m.description]));
  return {
    collapsed: false,
    sections: groups.map((g) => ({
      mount: g.mount,
      title: g.title,
      description: descriptionByName.get(g.mount) ?? '',
      rootRel: g.rootRel,
      tree: g.tree
    }))
  };
}

export type MountClassification = {
  /** Enabled, non-degraded — has (or will shortly have, once `icmStore` catches up) a `MountGroup`. */
  active: MountSummary[];
  /** `degraded !== null`, regardless of its `enabled` flag — always a non-clickable warning chip, never a tree section. */
  degraded: MountSummary[];
  /** `enabled: false` and NOT degraded — the collapsed "Deactivated" group, re-enabled via `mountsStore.setEnabled`. */
  deactivated: MountSummary[];
};

/**
 * Sorts the full mount catalog into the three groups the Knowledge page
 * renders. Degraded takes priority over deactivated — a mount that is both
 * `enabled: false` AND degraded is a manifest problem to surface, not
 * (only) a toggle to flip; `Valea.Mounts.effective?/1` excludes it from the
 * live tree either way, so there is nothing a re-enable toggle alone could
 * fix.
 */
export function classifyMounts(mounts: MountSummary[]): MountClassification {
  const active: MountSummary[] = [];
  const degraded: MountSummary[] = [];
  const deactivated: MountSummary[] = [];

  for (const mount of mounts) {
    if (mount.degraded) {
      degraded.push(mount);
    } else if (!mount.enabled) {
      deactivated.push(mount);
    } else {
      active.push(mount);
    }
  }

  return { active, degraded, deactivated };
}

/**
 * "Degraded — <reason>" chip text. `mount.degraded` is already a
 * human-readable reason string (e.g. "icm.yaml is missing", "invalid mount
 * directory name" — see `Valea.Mounts.load_manifest/1` and
 * `degraded_basename_mount/3`), so this only adds the fixed prefix. Falls
 * back to a generic reason for a `null` `degraded` — defensive only:
 * callers only invoke this for a mount already sorted into
 * `MountClassification.degraded`.
 */
export function degradedChipLabel(mount: Pick<MountSummary, 'degraded'>): string {
  return `Degraded — ${mount.degraded ?? 'unknown reason'}`;
}
