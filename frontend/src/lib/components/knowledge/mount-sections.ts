/**
 * Pure decision logic for the mounts-aware Knowledge UI (A-T15) — how
 * `icmStore.groups` (one `MountGroup` per ENABLED, non-degraded mount — see
 * `Valea.ICM.tree_for/1`'s moduledoc) and `mountsStore.mounts` (every
 * discovered mount, enabled or not, degraded or not — see
 * `Valea.Mounts.list/0`) combine into what the Knowledge page renders.
 * Same "extract the logic, no component render harness" convention as
 * `today/triage-card.ts`/`mail/mail-shapes.ts`.
 */

import type { MountGroup } from '$lib/stores/icm.svelte';
import type { MountSummary, PendingAdoptError } from '$lib/stores/mounts.svelte';
import type { IcmNode } from '$lib/shell/nav';

export type MountSection = {
  mount: string;
  title: string;
  description: string;
  /**
   * The mount's own resolved absolute physical root (`MountSummary.root`)
   * — shown as this section's location subtitle, since every mount is
   * by-reference (post-A2) and lives outside the workspace. Task 4.2
   * re-key: this is no longer usable as a create-parent path (that's now
   * always `""`, paired with `mount` — see `Valea.ICM.create_page/3`'s
   * `(mount_key, "", name)` shape) — it is presentation-only.
   */
  root: string;
  tree: IcmNode[];
};

/**
 * `collapsed: true` — the pre-mounts look: render `tree` directly at the
 * top level, no per-mount header. Chosen whenever there is AT MOST one
 * enabled mount (zero enabled mounts collapses to an empty `tree`, with
 * `mount: ''` — there's nothing to group, and nowhere to create into).
 * `collapsed: false` — two or more enabled mounts: one `MountSection`
 * (title + description header) per mount, backend order preserved.
 */
export type MountsDisplay =
  | { collapsed: true; mount: string; tree: IcmNode[] }
  | { collapsed: false; sections: MountSection[] };

/**
 * `groups` is `icmStore.groups` — the direct source of truth for what tree
 * data actually exists and how many mounts are effectively enabled.
 * `mounts` (`mountsStore.mounts`) supplies each section's header
 * `description`/`root`, which `MountGroup` itself doesn't carry (see
 * `Valea.Api.Icms.to_rpc_icm/1`). Joined by mount KEY — the stable
 * identifier both `MountGroup.mount` and `MountSummary.mountKey` share
 * (task 3.4: this used to be `MountSummary.name`, before that field became
 * the human display name), NOT `name` (which two mounts could
 * coincidentally share). A mount present in `groups` but missing from
 * `mounts` (a transient refetch-ordering gap between the two live stores,
 * which refresh together on `mounts_changed` but aren't atomic) degrades to
 * an empty description/root rather than throwing.
 */
export function buildMountsDisplay(groups: MountGroup[], mounts: MountSummary[]): MountsDisplay {
  if (groups.length <= 1) {
    return { collapsed: true, mount: groups[0]?.mount ?? '', tree: groups[0]?.tree ?? [] };
  }

  const byKey = new Map(mounts.map((m) => [m.mountKey, m]));
  return {
    collapsed: false,
    sections: groups.map((g) => ({
      mount: g.mount,
      title: g.title,
      description: byKey.get(g.mount)?.description ?? '',
      root: byKey.get(g.mount)?.root ?? '',
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

/**
 * Task 3.4: post-A2, `Valea.Mounts.list/1`'s `rel_root` is ALWAYS `nil` —
 * EVERY `list_icms` row is by-reference (external); there is no more
 * embedded mount kind for this to disambiguate from, and the new C9
 * `list_icms` payload doesn't even carry a `relRoot` field any more (see
 * `MountSummary`'s doc comment in `stores/mounts.svelte.ts`). Kept
 * (unconditionally `true`) rather than deleted, along with every
 * `{#if isExternalMount(mount)}` gate in `+page.svelte`, purely to keep
 * this task's diff to a rename — collapsing those gates away is deeper
 * Knowledge-UI work for a later task.
 */
export function isExternalMount(_mount: MountSummary): boolean {
  return true;
}

// -- mounts doctor: check-row shaping (backend: `Valea.Mounts.Doctor.run/1`,
// `mounts_doctor`'s `checks` field — UNCONSTRAINED `:map`, same as
// `mail_doctor`, see `Valea.Api.Mounts`'s moduledoc — so it arrives as
// loosely-typed `Record<string, any>[]` and must be narrowed defensively,
// mirroring `mail-shapes.ts`'s `normalizeMailDoctorChecks` exactly) --------

export type MountsDoctorCheck = {
  id: string;
  label: string;
  status: string;
  detail: string;
  remedy: string | null;
};

/** Narrows `mounts_doctor`'s raw `checks` payload; an entry with no `id` is dropped rather than rendered as a mystery row. */
export function normalizeMountsDoctorChecks(raw: unknown): MountsDoctorCheck[] {
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((entry): MountsDoctorCheck[] => {
    if (!entry || typeof entry !== 'object') return [];
    const rec = entry as Record<string, unknown>;
    const id = typeof rec.id === 'string' ? rec.id : '';
    if (!id) return [];

    const label = typeof rec.label === 'string' ? rec.label : id;
    const status = typeof rec.status === 'string' ? rec.status : 'unknown';
    const detail = typeof rec.detail === 'string' ? rec.detail : '';
    const remedy = typeof rec.remedy === 'string' ? rec.remedy : null;
    return [{ id, label, status, detail, remedy }];
  });
}

/**
 * The Knowledge page's adoption-failure banner copy (fix wave 1, A2-T9) —
 * rendered from `mountsStore.pendingAdoptError` after a declare-stage
 * reference-adoption failure survived the onboarding-to-app transition
 * (see `PendingAdoptError`'s doc comment in `stores/mounts.svelte.ts`).
 * `message` is already-mapped readable copy (a full sentence ending in a
 * period), so this only frames it with WHAT failed (name + source ref) and
 * the retry affordance — which lives one glance away in the same pane's
 * footer.
 */
export function adoptFailureBannerText(pending: PendingAdoptError): string {
  return (
    `Couldn't mount "${pending.name}" from ${pending.ref}: ${pending.message} ` +
    'You can retry from "Mount a folder from elsewhere…".'
  );
}
