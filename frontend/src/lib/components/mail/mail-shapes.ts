/**
 * Pure, unit-testable helpers for the `/mail` route's four components
 * (`MessageList`, `MessageView`, `SyncStatusLine`, `InboxSection`) — same
 * "no component render harness; extract the logic instead" convention as
 * `components/audit/sentence.ts` and `components/agent/item-shapes.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - message summary (`MailMessageSummary`): `Valea.Mail.Store.list_messages/0`
 *    (via `list_mail_messages`'s `listMailMessagesFields`).
 *  - message detail frontmatter: `Valea.Mail.MessageFile.render/2`'s field
 *    order (id, message_id, from, to, subject, date, uid, in_reply_to,
 *    references, reply_to, status, source, source_ref, attachments), parsed
 *    back by `MessageFile.parse/1` via `YamlElixir.read_from_string/1` —
 *    string keys, `from`/`reply_to` are `{name, email} | null`, `to` is
 *    `[{name, email}]`, `attachments` is `[{filename, path, bytes}]`.
 *  - status values: `"review" | "processed"` (`MessageFile.parse/1`'s doc
 *    comment; flipped by `Valea.Mail.MailboxOps.flip_status/2`).
 *  - engine state: `"idle" | "inactive" | "syncing" | "auth_failed"`
 *    (`MailStatusPush`'s doc comment in `socket.ts`).
 */

import type { MailStatus } from '$lib/stores/mail.svelte';

// -- status → dot (DESIGN_SYSTEM §8: "status badges show the assistant's
// work at a glance") -------------------------------------------------------

export type MessageDotColor = 'act' | 'neutral';

/** Tailwind utility class for the dot's background, keyed by color — same shape as `AUDIT_DOT_CLASS`/`SOURCE_DOT_CLASS`. */
export const MESSAGE_DOT_CLASS: Record<MessageDotColor, string> = {
  act: 'bg-act-dot',
  neutral: 'bg-ink-meta'
};

/** Green accent dot for a message still awaiting review; neutral (muted ink) for everything else, including "processed". */
export function messageDot(status: string | null | undefined): MessageDotColor {
  return status === 'review' ? 'act' : 'neutral';
}

export function isProcessed(status: string | null | undefined): boolean {
  return status === 'processed';
}

// -- relative time — mirrors `routes/chat/+page.svelte`'s `relativeTime` ---
// (this codebase duplicates this small helper per call site rather than
// centralizing it; kept here, not inline in a component, purely so it's
// unit-testable per this module's "no render harness" convention).
export function relativeTime(iso: string | null | undefined): string {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
  const deltaSeconds = Math.round((date.getTime() - Date.now()) / 1000);
  const abs = Math.abs(deltaSeconds);
  if (abs < 60) return rtf.format(deltaSeconds, 'second');
  if (abs < 3600) return rtf.format(Math.round(deltaSeconds / 60), 'minute');
  if (abs < 86400) return rtf.format(Math.round(deltaSeconds / 3600), 'hour');
  return rtf.format(Math.round(deltaSeconds / 86400), 'day');
}

/** "14:32, Jul 10, 2026"-ish absolute rendering for the detail header — deliberately distinct from the list's relative time. */
export function formatDateTime(iso: string | null | undefined): string {
  if (!iso) return '';
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return '';
  return date.toLocaleString(undefined, { dateStyle: 'medium', timeStyle: 'short' });
}

// -- from/subject fallbacks (MessageList reads `MailMessageSummary`) -------

export function fromLabel(message: { fromName?: string | null; fromEmail?: string | null }): string {
  const name = message.fromName?.trim();
  if (name) return name;
  const email = message.fromEmail?.trim();
  if (email) return email;
  return '(unknown sender)';
}

export function subjectLabel(subject: string | null | undefined): string {
  const s = subject?.trim();
  return s ? s : '(no subject)';
}

/** Generic trimmed-or-fallback — `InboxSection`'s raw IMAP headers (`fromText`/`subject`) are single strings, not split name/email. */
export function nonEmpty(value: string | null | undefined, fallback: string): string {
  const v = value?.trim();
  return v ? v : fallback;
}

// -- address formatting for MessageView's header block ----------------------

export type RawAddress = { name?: unknown; email?: unknown } | null | undefined;

/** "Name <email>", or whichever of the two is present, or "" for neither/not-an-address. */
export function addressLabel(addr: RawAddress): string {
  if (!addr || typeof addr !== 'object') return '';
  const name = typeof addr.name === 'string' ? addr.name.trim() : '';
  const email = typeof addr.email === 'string' ? addr.email.trim() : '';
  if (name && email) return `${name} <${email}>`;
  return name || email;
}

/** Comma-joined `addressLabel` over a `to`-style address list; "" for a non-array or all-blank entries. */
export function addressListLabel(list: unknown): string {
  if (!Array.isArray(list)) return '';
  return list
    .map((entry) => addressLabel(entry as RawAddress))
    .filter((s) => s.length > 0)
    .join(', ');
}

// -- attachments --------------------------------------------------------------

export type Attachment = { filename: string; path: string; bytes: number };

/** `frontmatter.attachments` (`[{filename, path, bytes}]`), defensively narrowed — a malformed entry is dropped, never thrown on. */
export function attachmentsFromFrontmatter(
  frontmatter: Record<string, unknown> | null | undefined
): Attachment[] {
  if (!frontmatter) return [];
  const raw = frontmatter.attachments;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((entry): Attachment[] => {
    if (!entry || typeof entry !== 'object') return [];
    const rec = entry as Record<string, unknown>;
    const filename = typeof rec.filename === 'string' ? rec.filename : '';
    const path = typeof rec.path === 'string' ? rec.path : '';
    const bytes = typeof rec.bytes === 'number' ? rec.bytes : 0;
    if (!filename || !path) return [];
    return [{ filename, path, bytes }];
  });
}

/** Human-readable size: whole bytes under 1KB, one decimal below 10 units, whole numbers from 10 up — never throws on bad input. */
export function formatBytes(bytes: number): string {
  if (!Number.isFinite(bytes) || bytes <= 0) return '0 B';
  if (bytes < 1024) return `${Math.round(bytes)} B`;

  const units = ['KB', 'MB', 'GB', 'TB'];
  let value = bytes / 1024;
  let unitIndex = 0;
  while (value >= 1024 && unitIndex < units.length - 1) {
    value /= 1024;
    unitIndex += 1;
  }
  const rounded = value >= 10 ? Math.round(value) : Math.round(value * 10) / 10;
  return `${rounded} ${units[unitIndex]}`;
}

// -- Run triage gating (mirrors `today/InquiryTriageCard.svelte`'s in-flight
// guard; `processed` additionally locks the action out entirely — a
// processed message renders a "Processed" badge instead of the button, see
// `MessageView.svelte`) -------------------------------------------------------

/** `false` while a run is in flight, or once the message is already `processed` — a `null`/unknown status is treated as runnable. */
export function canRunTriage(status: string | null | undefined, busy: boolean): boolean {
  return status !== 'processed' && !busy;
}

// -- SyncStatusLine ------------------------------------------------------------

export function mailStateLabel(state: string | null | undefined): string {
  switch (state) {
    case 'idle':
      return 'Up to date';
    case 'syncing':
      return 'Syncing…';
    case 'auth_failed':
      return 'Sign-in failed';
    case 'inactive':
      return 'Not connected';
    default:
      // A future engine state this UI hasn't been taught about yet still
      // renders SOMETHING sane (its raw name) rather than a blank line —
      // same "never crash on an unrecognized value" posture as
      // `sentence.ts`'s `default` branch. `null`/`undefined` (no status
      // loaded yet) gets its own distinct label.
      return state ? state : 'Unknown';
  }
}

/** Local request error (the `syncNow` RPC call itself failing) wins over the engine's own `lastError`; `null` when neither is present. */
export function syncErrorText(status: MailStatus | null, requestError: string | null): string | null {
  return requestError ?? status?.lastError ?? null;
}

export function syncNowErrorMessage(code: string): string {
  switch (code) {
    case 'not_configured':
      return 'Connect your mailbox first.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    default:
      return 'Could not start a sync. Please try again.';
  }
}
