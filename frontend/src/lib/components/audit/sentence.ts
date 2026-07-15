import type { AuditEntry } from '$lib/api/client';

/**
 * Plain-sentence rendering for `logs/audit.jsonl` entries. Every entry type
 * here is grepped straight from the backend's `Valea.Audit.append`/
 * `append_sync` call sites — the exact field set each type carries, not a
 * guess:
 *
 *   - `Valea.Workflows.Runner` (`run/2`/`finalize/2`):
 *     `workflow_run_started` {run_id, workflow, input, workflow_hash, input_hash}
 *     — `workflow` is a `{icm_id, relative_path, resolved_path}` map as of
 *     Task 7.4 (was a bare `resolved_path` string pre-7.4; older audit.jsonl
 *     entries on disk still carry the string shape, so both are handled),
 *     `workflow_run_finished` {run_id, outcome, reason?} (outcome one of
 *     "no_proposal" | "invalid_proposal" | "proposal_created" | "start_failed"),
 *     `queue_item_created` {run_id, kind}.
 *   - `Valea.Queue` (`approve/2`/`reject/2`/`recover/1`):
 *     `approval_intent` {run_id}, `action_executed` {run_id},
 *     `item_approved` {run_id, recovered?}, `item_rejected` {run_id},
 *     `approval_recovered` {run_id}.
 *   - `Valea.Agents.SessionServer` (`policy_decide/2`/`answer_permission`):
 *     `permission_auto_allowed` {item_id, title, kind, decision},
 *     `permission_auto_denied` {item_id, title, kind, decision},
 *     `permission_asked` {item_id, title, kind, decision},
 *     `permission_answered` {item_id, kind}.
 *
 * None of these carry a `title` for the underlying proposal (only the
 * permission_* family's ACP tool-call title) or a `session_id` — the audit
 * trail is a forensic record of WHAT HAPPENED, not a denormalized copy of
 * the queue item. Sentences below read naturally off exactly the fields
 * that exist; `run_id`/`session_id` (when present, defensively — see
 * `reviewHref`/`transcriptHref`) drive the row's "review →"/"transcript →"
 * links instead of being spelled out in prose.
 *
 * The `default` branch must never crash and must never throw on a
 * partially-shaped entry — this reads directly off the wire (see
 * `AuditEntry`'s doc comment in `api/client.ts`), so a future audit type
 * this file hasn't been taught about yet still renders SOMETHING sane.
 */

function str(value: unknown): string {
  return typeof value === 'string' && value !== '' ? value : '';
}

function basename(path: unknown): string {
  const p = str(path);
  if (!p) return 'a workflow';
  const file = p.split('/').pop() ?? p;
  return file.endsWith('.md') ? file.slice(0, -3) : file;
}

/**
 * `workflow_run_started`'s `workflow` field: a bare path string pre-Task-7.4,
 * or a `{icm_id, relative_path, resolved_path}` map as of Task 7.4 (see
 * `Valea.Workflows.Runner`'s audit call). Prefers `relative_path` (the
 * stable `{icm_id, relative_path}` identity) over `resolved_path` (the
 * physical path used for that one run, which a later move/remount can
 * change), falling back to `resolved_path` if `relative_path` is somehow
 * missing. Never throws on an unexpected shape — see module doc.
 */
function workflowName(workflow: unknown): string {
  if (workflow && typeof workflow === 'object') {
    const w = workflow as Record<string, unknown>;
    return basename(str(w.relative_path) || str(w.resolved_path));
  }
  return basename(workflow);
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
    case 'workflow_run_started': {
      const name = workflowName(entry.workflow);
      const input = str(entry.input);
      return input ? `Started "${name}" on ${input}.` : `Started "${name}".`;
    }

    case 'workflow_run_finished': {
      switch (entry.outcome) {
        case 'proposal_created':
          return 'Workflow run finished — a proposal is waiting for review.';
        case 'no_proposal':
          return 'Workflow run finished — no proposal was produced.';
        case 'invalid_proposal':
          return "Workflow run finished — the proposal couldn't be read.";
        case 'start_failed':
          return 'Workflow run failed to start.';
        default:
          return 'Workflow run finished.';
      }
    }

    case 'queue_item_created': {
      const kind = humanize(entry.kind);
      return kind ? `New proposal queued: ${kind}.` : 'New proposal queued.';
    }

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

    case 'approval_intent':
      return 'Approval started — about to act on this proposal.';

    case 'item_approved':
      return entry.recovered === true
        ? 'You approved this proposal after a restart — draft created.'
        : 'You approved this proposal — draft created.';

    case 'item_rejected':
      return 'You rejected this proposal.';

    case 'action_executed':
      return 'Draft created.';

    case 'approval_recovered':
      return 'An interrupted approval was recovered — returned to pending for review.';

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
  if (type === 'item_approved' || type === 'action_executed') return 'green';
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

/** `/queue/<run_id>` when the entry carries a `run_id`, else `null`. */
export function reviewHref(entry: AuditEntry): string | null {
  const runId = str(entry.run_id);
  return runId ? `/queue/${encodeURIComponent(runId)}` : null;
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
 * checked, defensively (never throws on a malformed/future entry):
 *
 *   - `workflow_run_started`'s `workflow` field: `{icm_id, relative_path,
 *     resolved_path}` (Task 7.4) — the SAME object `workflowName` reads,
 *     minus the pre-7.4 bare-string back-compat case (a bare string names
 *     no ICM).
 *   - `action_executed`/`apply_conflict`'s `target` field (`Valea.Queue`'s
 *     memory-update path only — an `email_draft`'s `action_executed` has
 *     no `target` at all): `{locator: {kind: "icm", icm_id, path},
 *     resolved_path}`.
 */
function auditIcmId(entry: AuditEntry): string | null {
  const workflow = entry.workflow;
  if (workflow && typeof workflow === 'object') {
    const id = str((workflow as Record<string, unknown>).icm_id);
    if (id) return id;
  }

  const target = entry.target;
  if (target && typeof target === 'object') {
    const locator = (target as Record<string, unknown>).locator;
    if (locator && typeof locator === 'object') {
      const id = str((locator as Record<string, unknown>).icm_id);
      if (id) return id;
    }
  }

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
