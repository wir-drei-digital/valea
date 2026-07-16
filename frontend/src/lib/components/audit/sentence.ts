import type { AuditEntry } from '$lib/api/client';

/**
 * Plain-sentence rendering for `logs/audit.jsonl` entries. Every entry type
 * here is grepped straight from the backend's `Valea.Audit.append`/
 * `append_sync` call sites — the exact field set each type carries, not a
 * guess:
 *
 *   - `Valea.Agents.SessionServer` (`policy_decide/2`/`answer_permission`):
 *     `permission_auto_allowed` {item_id, title, kind, decision},
 *     `permission_auto_denied` {item_id, title, kind, decision},
 *     `permission_asked` {item_id, title, kind, decision},
 *     `permission_answered` {item_id, kind}.
 *
 * None of these carry a `title` for the underlying proposal (only the
 * permission_* family's ACP tool-call title) or a `session_id` — the audit
 * trail is a forensic record of WHAT HAPPENED, not a denormalized copy of
 * whatever produced it. Sentences below read naturally off exactly the
 * fields that exist; `session_id` (when present, defensively — see
 * `transcriptHref`) drives the row's "transcript →" link instead of being
 * spelled out in prose.
 *
 * The `default` branch must never crash and must never throw on a
 * partially-shaped entry — this reads directly off the wire (see
 * `AuditEntry`'s doc comment in `api/client.ts`), so a future audit type
 * this file hasn't been taught about yet still renders SOMETHING sane (e.g.
 * `session_exited` has no dedicated case and relies on this fallback).
 */

function str(value: unknown): string {
  return typeof value === 'string' && value !== '' ? value : '';
}

/** "allow_once" -> "allow once"; "email.selected" -> "email selected". */
function humanize(value: unknown): string {
  const s = str(value);
  return s ? s.replaceAll('_', ' ').replaceAll('.', ' ') : '';
}

function capitalize(s: string): string {
  return s.length ? s.charAt(0).toUpperCase() + s.slice(1) : s;
}

export function sentence(entry: AuditEntry): string {
  switch (entry.type) {
    case 'permission_auto_allowed': {
      const title = str(entry.title);
      return title ? `Allowed automatically: ${title}.` : 'Allowed automatically by policy.';
    }

    case 'permission_auto_denied': {
      const title = str(entry.title);
      return title ? `Denied automatically: ${title}.` : 'Denied automatically by policy.';
    }

    case 'permission_asked': {
      const title = str(entry.title);
      return title ? `Asked for permission: ${title}.` : 'Asked for permission.';
    }

    case 'permission_answered': {
      const kind = humanize(entry.kind);
      return kind ? `You answered a permission request: ${kind}.` : 'You answered a permission request.';
    }

    default: {
      const label = humanize(entry.type);
      return label ? `${capitalize(label)}.` : 'Unrecognized event.';
    }
  }
}

/** Dot/icon color family for a receipt row, keyed by audit type prefix/exact match. */
export type AuditDotColor = 'amber' | 'green' | 'ink';

export function auditDot(type: string): AuditDotColor {
  if (type.startsWith('permission_')) return 'amber';
  return 'ink';
}

/** Tailwind utility class for the dot's background, keyed by `auditDot`'s color. */
export const AUDIT_DOT_CLASS: Record<AuditDotColor, string> = {
  amber: 'bg-suggest-dash',
  green: 'bg-act-dot',
  ink: 'bg-ink-meta'
};

/** `/chat?session=<id>` when the entry (defensively — see module doc) carries a `session_id`, else `null`. */
export function transcriptHref(entry: AuditEntry): string | null {
  const sessionId = str(entry.session_id);
  return sessionId ? `/chat?session=${encodeURIComponent(sessionId)}` : null;
}

/** "14:32" local time, or "" for an unparseable timestamp — mirrors `PageMeta.svelte`'s `formatSavedAt`. */
export function formatAuditTimestamp(ts: string): string {
  const parsed = new Date(ts);
  if (Number.isNaN(parsed.getTime())) return '';
  return parsed.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
}

// -- ICM provenance (Task 9.5) ---------------------------------------------

/**
 * A row from `list_icms` — the minimal shape `auditIcmName` needs to
 * resolve an entry's owning ICM to a display name. Declared locally
 * (rather than importing `MountSummary` from `stores/mounts.svelte.ts`) to
 * keep this module free of a store dependency, same "no component render
 * harness, pure logic only" posture as the rest of this file; a real
 * `MountSummary[]` (which has these three fields plus more) satisfies this
 * structurally.
 */
export type AuditIcmDirectoryEntry = { id: string | null; mountKey: string; name: string };

/**
 * The `icm_id` an audit entry names, or `null` — the audit trail is
 * heterogeneous by `type` (see module doc), so only the shapes an actual
 * `Valea.Audit.append`/`append_sync` call site is known to carry are
 * checked, defensively (never throws on a malformed/future entry). No
 * currently-surviving entry type carries an `icm_id`-bearing field (the
 * `workflow`/`target` shapes that used to were removed with the
 * queue/workflow subsystem, Spec D deletion wave) — kept as its own
 * function so a future ICM-scoped entry type has a single place to add a
 * lookup branch, rather than inlining `null` into `auditIcmName` below.
 */
function auditIcmId(_entry: AuditEntry): string | null {
  return null;
}

/**
 * The `mount_key` an audit entry names directly, or `null` — only
 * `Valea.Mounts`'s own `icm_mounted`/`icm_unmounted` audit calls carry
 * this (already the workspace-local config key, no id-to-key resolution
 * needed).
 */
function auditMountKey(entry: AuditEntry): string | null {
  return str(entry.mount_key) || null;
}

/**
 * The display name of the ICM an audit entry names, resolved against
 * `mounts` (`list_icms`, already fetched app-wide by the shared sidebar —
 * see `AuditRow.svelte`), or `null` when the entry names no ICM at all, or
 * names one no longer in `mounts` (unmounted since, or a degraded mount
 * with no `id`). Tries `icm_id` first (stable across a mount being
 * renamed/re-keyed), then falls back to `mount_key` (the one signal
 * `icm_mounted`/`icm_unmounted` carry, since by the time an ICM is
 * unmounted its id is no longer worth resolving by) — never invents a
 * name for an entry that doesn't carry one.
 */
export function auditIcmName(entry: AuditEntry, mounts: AuditIcmDirectoryEntry[]): string | null {
  const icmId = auditIcmId(entry);
  if (icmId) {
    const byId = mounts.find((m) => m.id === icmId);
    if (byId) return byId.name;
  }

  const mountKey = auditMountKey(entry);
  if (mountKey) {
    const byMountKey = mounts.find((m) => m.mountKey === mountKey);
    if (byMountKey) return byMountKey.name;
  }

  return null;
}
