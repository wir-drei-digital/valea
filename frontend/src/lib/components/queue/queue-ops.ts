/**
 * Pure, unit-testable helpers for `routes/queue/[run_id]/+page.svelte`'s
 * DECIDED-item view (Task 18: mailbox-op outcome surfacing) — same
 * "no component render harness; extract the logic instead" convention as
 * `components/mail/mail-shapes.ts` and `components/audit/sentence.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - decided list entry: `Valea.Queue.list_decided/0`'s `decided_entry/2`
 *    (`run_id`, `decided` ("approved" | "rejected"), `title`, `kind`, the
 *    raw `mailbox_ops` map or `nil`, `created_at`, `decision` (`nil` |
 *    `%{"reason" => reason}`, present only when `reject/3` was given a
 *    non-blank reason — B6/B12), `decided_at`) — delivered RAW/snake_case
 *    over RPC (`list_decided_items`'s `items` field is deliberately
 *    UNCONSTRAINED, see `Valea.Api.Queue`'s moduledoc). Note: this entry
 *    shape does NOT carry the memory item's `target_path` (that only lives
 *    inside the full pending/approved envelope, which `list_decided_items`
 *    never reads) — the decided view falls back to the item's `title`
 *    (`"Update <basename>"` / `"New page: <basename>"`, B12) for context
 *    on an approved memory item rather than fabricate a path.
 *  - mailbox op status map: `Valea.Mail.MailboxOps`'s moduledoc ("Per-op
 *    status machine") — `"pending" | "done" | "unsupported" | "failed"`
 *    (plus `"skipped"`, seeded by `Valea.Queue`'s `mailbox_ops_for/3` for a
 *    seed-source item), each `%{"status" => ..., "error" => ...}` (`"error"`
 *    only on `"failed"`/`"unsupported"`).
 *  - op names/order: `Valea.Mail.MailboxOps.@op_order` — `"draft_append"`
 *    then `"archive_source"`; a reject/2 envelope only ever seeds
 *    `"archive_source"` (`Valea.Queue.complete_rejection/3`).
 */

// -- decided item -------------------------------------------------------

export type DecidedQueueItem = {
  runId: string;
  /** `"approved" | "rejected"` — kept as a plain string (not a union) since an unrecognized value must still render SOMETHING, never crash. */
  decided: string;
  title: string | null;
  kind: string | null;
  /** Raw `mailbox_ops` map, or `null` for a non-`email_draft` decided item — feed straight into `mailboxOpRows`. */
  mailboxOps: unknown;
  createdAt: string | null;
  /** The human's rejection reason (B6/B12), or `null` — never present on an approved item. */
  decision: { reason: string } | null;
};

/** Narrows one raw `list_decided_items` entry; `null` for anything missing a usable `run_id`. */
export function normalizeDecidedItem(raw: unknown): DecidedQueueItem | null {
  if (!raw || typeof raw !== 'object') return null;
  const rec = raw as Record<string, unknown>;

  const runId = firstString(rec.run_id, rec.runId);
  if (!runId) return null;

  return {
    runId,
    decided: typeof rec.decided === 'string' ? rec.decided : 'approved',
    title: typeof rec.title === 'string' ? rec.title : null,
    kind: typeof rec.kind === 'string' ? rec.kind : null,
    mailboxOps: rec.mailbox_ops ?? rec.mailboxOps ?? null,
    createdAt: firstString(rec.created_at, rec.createdAt),
    decision: normalizeDecision(rec.decision)
  };
}

/** `nil`/absent → `null`; a `%{"reason" => "..."}` map with a non-blank string reason → `{reason}`; anything else (malformed) also collapses to `null` rather than rendering garbage. */
function normalizeDecision(raw: unknown): { reason: string } | null {
  if (!raw || typeof raw !== 'object') return null;
  const reason = (raw as Record<string, unknown>).reason;
  return typeof reason === 'string' && reason.trim() !== '' ? { reason } : null;
}

/** Finds `runId` among `list_decided_items`'s raw `items` array; `null` if absent (not decided, or genuinely gone). */
export function findDecidedItem(items: unknown[], runId: string): DecidedQueueItem | null {
  for (const raw of items) {
    const item = normalizeDecidedItem(raw);
    if (item && item.runId === runId) return item;
  }
  return null;
}

function firstString(...values: unknown[]): string | null {
  for (const value of values) {
    if (typeof value === 'string') return value;
  }
  return null;
}

// -- mailbox-op rows ------------------------------------------------------

export type MailboxOpChip = 'neutral' | 'act' | 'warn';

/** Tailwind pill classes keyed by chip color — same shape as `mail-shapes.ts`'s `MESSAGE_DOT_CLASS`. */
export const MAILBOX_OP_CHIP_CLASS: Record<MailboxOpChip, string> = {
  neutral: 'bg-paper-track text-ink-secondary',
  act: 'bg-act-tint text-act',
  warn: 'bg-warn-tint text-warn-ink'
};

export type MailboxOpRow = {
  name: string;
  label: string;
  status: string;
  chip: MailboxOpChip;
  statusText: string;
  /** Extra detail line — the failure/unsupported reason; `null` otherwise. */
  hint: string | null;
  canRetry: boolean;
};

const OP_ORDER = ['draft_append', 'archive_source'] as const;

const OP_LABELS: Record<string, string> = {
  draft_append: 'Draft in your mail app',
  archive_source: 'Original filed to AI/Processed'
};

export function mailboxOpLabel(name: string): string {
  return OP_LABELS[name] ?? name;
}

/** `done` reads as the one "good news" green; `failed` is the one that needs attention; everything else (pending/skipped/unsupported) is neutral informational. */
export function mailboxOpChip(status: string): MailboxOpChip {
  switch (status) {
    case 'done':
      return 'act';
    case 'failed':
      return 'warn';
    default:
      return 'neutral';
  }
}

export function mailboxOpStatusText(status: string): string {
  switch (status) {
    case 'pending':
      return 'Pending';
    case 'done':
      return 'Done';
    case 'failed':
      return 'Failed';
    case 'skipped':
      return 'Not needed (sample message)';
    case 'unsupported':
      return "Needs a manual move — your mail server doesn't support automatic moves";
    default:
      // A future/unrecognized status still renders SOMETHING sane (its raw
      // name) rather than a blank chip — same posture as `mail-shapes.ts`'s
      // `mailStateLabel` default branch.
      return status;
  }
}

/**
 * Builds the ordered row list from a decided item's raw `mailboxOps` map —
 * `draft_append` before `archive_source` regardless of key order, and only
 * for ops that are ACTUALLY present (a reject/2 envelope has no
 * `draft_append` at all). `null`/non-map input (a non-`email_draft` decided
 * item) yields an empty list, so the page can just check `.length` to decide
 * whether to render the ops section at all.
 */
export function mailboxOpRows(mailboxOps: unknown): MailboxOpRow[] {
  if (!mailboxOps || typeof mailboxOps !== 'object') return [];
  const ops = mailboxOps as Record<string, unknown>;

  return OP_ORDER.flatMap((name): MailboxOpRow[] => {
    const raw = ops[name];
    if (!raw || typeof raw !== 'object') return [];

    const rec = raw as Record<string, unknown>;
    const status = typeof rec.status === 'string' ? rec.status : 'unknown';
    const error = typeof rec.error === 'string' ? rec.error : null;

    return [
      {
        name,
        label: mailboxOpLabel(name),
        status,
        chip: mailboxOpChip(status),
        statusText: mailboxOpStatusText(status),
        hint: status === 'failed' || status === 'unsupported' ? error : null,
        canRetry: status === 'failed'
      }
    ];
  });
}

// -- retry_mailbox_ops error mapping ---------------------------------------

/**
 * `retry_mailbox_ops`'s error vocabulary: the generation guard's
 * `workspace_not_open`/`workspace_changed`, plus `Engine.retry_ops/1`'s own
 * gate (`inactive | not_configured | no_credential` — the same
 * `validate_sync/1` gate `mail-shapes.ts`'s `createFoldersErrorMessage`
 * documents for `create_mail_folders`).
 */
export function retryMailboxOpsErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
    case 'inactive':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'not_configured':
      return 'Connect your mailbox first.';
    case 'no_credential':
      return 'Enter your mailbox password first.';
    default:
      return 'Could not retry. Please try again.';
  }
}
