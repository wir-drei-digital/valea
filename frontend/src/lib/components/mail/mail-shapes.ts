/**
 * Pure, unit-testable helpers for the `/mail` route's components
 * (`AccountSwitcher`, `FolderList`, `MessageList`, `MessageView`,
 * `SyncStatusLine`, `SetupPanel`, `MailDoctorPanel`) — same "no component
 * render harness; extract the logic instead" convention as
 * `components/audit/sentence.ts` and `components/agent/item-shapes.ts`.
 *
 * Field shapes are sourced from the emitting Elixir code, not guessed:
 *  - account status (`MailAccountStatus`): `Valea.Mail.Engine.status/1` via
 *    `mail_status`'s `accounts` list, normalized in `stores/mail.svelte.ts`.
 *  - folder rows (`MailFolder`): `list_mail_folders`.
 *  - message summary (`MailMessageSummary`): `list_mail_messages`.
 *  - message detail frontmatter: `Valea.Mail.MessageFile.render/2`'s field
 *    order (id, message_id, account, folders, flags, from, to, subject,
 *    date, in_reply_to, references, reply_to, attachments), parsed back by
 *    `MessageFile.parse/1` via `YamlElixir.read_from_string/1` — string
 *    keys, `from`/`reply_to` are `{name, email} | null`, `to` is
 *    `[{name, email}]`, `attachments` is `[{filename, path, bytes}]`.
 *  - engine state: `"idle" | "inactive" | "syncing" | "auth_failed" |
 *    "identity_mismatch" | "mailbox_replaced"` (`MailStatusPush`'s doc
 *    comment in `socket.ts`), plus the RPC-only `"invalid_config"`.
 */

import type { MailAccountStatus, MailDraft, MailDraftReview, MailFolder } from '$lib/stores/mail.svelte';
import type { Api, MailSmtpSetup } from '$lib/api/client';

// -- account/folder chrome (AccountSwitcher / FolderList) -------------------

/**
 * The account slug grammar, mirrored client-side from
 * `Valea.Mail.Settings.valid_slug?/1` so the setup form can reject before
 * the RPC round-trip. The backend remains the authority — `setup_mail_account`
 * re-validates and answers `"invalid_slug"`.
 */
export const MAIL_SLUG_RE = /^[a-z0-9][a-z0-9-]{0,31}$/;

export function mailSlugValid(slug: string): boolean {
  return MAIL_SLUG_RE.test(slug);
}

/** Switcher option text: the slug, with a broken account marked inline rather than hidden. */
export function accountLabel(status: Pick<MailAccountStatus, 'account' | 'valid'>): string {
  return status.valid ? status.account : `${status.account} (invalid)`;
}

/**
 * Lowercase-hex sha256 of a UTF-8 string — byte-for-byte the encoding of
 * the backend's `Valea.Mail.DraftFile.content_hash/1`, so the push CAS
 * (`push_draft_to_mailbox`'s `contentHash`) binds to exactly the revision
 * `getMailDraft` returned. Web Crypto; async by nature.
 */
export async function sha256Hex(content: string): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(content));
  return Array.from(new Uint8Array(digest))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

/** Badge text for a folder row (`FolderList`): `"held"` for a held folder (spec E §folder lifecycle), nothing otherwise. */
export function folderBadge(folder: Pick<MailFolder, 'held'>): string | null {
  return folder.held ? 'held' : null;
}

// -- ops actions (MessageView) ----------------------------------------------

/**
 * User copy for one `mail_apply_ops` per-op outcome. `accepted`/`complete`
 * count as success (`null` — nothing to show); everything else maps the
 * executor's rejection reasons to calm sentences.
 */
export function opResultMessage(result: string, reason: string | null): string | null {
  if (result === 'accepted' || result === 'complete') return null;

  switch (reason) {
    case 'server_changed':
      return 'The message changed on the server. Sync and try again.';
    case 'no_credential':
      return 'Enter your mailbox password first.';
    case 'blocked':
    case 'mailbox_replaced':
      return 'This account is blocked pending re-adopt.';
    case 'inactive':
    case 'not_configured':
      return 'Connect your mailbox first.';
    default:
      return reason ? `The action was rejected (${reason}).` : 'The action was rejected.';
  }
}

/**
 * Opening prompt for the "Clean up inbox" session (mail design spec E §UI,
 * exact text pinned by the plan's Task-16 contract).
 */
export function cleanupPrompt(slug: string): string {
  return (
    `You have the mail account '${slug}' mounted read-only at its mail mount. ` +
    `Review INBOX via the views/ folder, then declare cleanup as a YAML ops file in ops/pending/ ` +
    `(vocabulary: move, flag) — the engine validates and executes them. Never modify maildir/ directly. ` +
    `Propose, don't over-file: when unsure, leave a message where it is.`
  );
}

// -- drafts (DraftsPanel) ----------------------------------------------------

/** Badge label + tone for a draft's ledger-derived display state. */
export function draftStatusBadge(statusDisplay: string): { label: string; tone: 'neutral' | 'busy' | 'ok' | 'warn' } {
  switch (statusDisplay) {
    case 'pushing':
      return { label: 'Pushing…', tone: 'busy' };
    case 'pushed':
      return { label: 'Pushed', tone: 'ok' };
    case 'needs_review':
      return { label: 'Needs review', tone: 'warn' };
    case 'rejected':
      return { label: 'Rejected', tone: 'warn' };
    // -- send (spec G). `send_review` is not an error and not a failure: the
    // outcome is genuinely unknown and only the human can settle it, so the
    // badge asks rather than accuses.
    case 'sending':
      return { label: 'Sending…', tone: 'busy' };
    case 'send_review':
      return { label: 'Needs your answer', tone: 'warn' };
    case 'sent':
      return { label: 'Sent', tone: 'ok' };
    default:
      return { label: 'Draft', tone: 'neutral' };
  }
}

/** One-line recipient summary: `"To alex@example.com, Bo <bo@x> · Subject"`, or the invalid reason. */
export function draftRecipientsLine(recipients: MailDraft['recipients']): string {
  if ('invalid' in recipients) return `Invalid draft (${recipients.invalid})`;

  const to = recipients.to.map((a) => (a.name ? `${a.name} <${a.email}>` : a.email)).join(', ');
  const parts = [];
  if (to) parts.push(`To ${to}`);
  if (recipients.subject) parts.push(recipients.subject);
  return parts.join(' · ') || '(no recipients)';
}

/**
 * A draft row's ledger notice as a sentence. Only the fixed vocabulary is
 * translated; a rejected op's notice is a composed reason string (with its
 * transport detail already redacted backend-side) and is the most specific
 * thing available, so it passes through verbatim rather than being flattened
 * into something vaguer.
 */
export function draftNoticeMessage(notice: string | null): string | null {
  switch (notice) {
    case null:
      return null;
    case 'earlier_revision_sent':
      return 'An earlier revision of this draft was sent. This file has changed since.';
    case 'status_forged':
      return "This draft's status was written by something other than Valea, so it is being ignored.";
    case 'sent_copy_failed':
      return "This was sent, but the copy for your Sent folder didn't land.";
    default:
      return notice;
  }
}

/** Error copy for a failed push (`push_draft_to_mailbox` / `get_mail_draft` error codes). */
export function pushErrorMessage(code: string): string {
  switch (code) {
    case 'content_changed':
      return 'The draft changed since you opened it. Review it again, then push.';
    case 'duplicate_active':
      return 'This draft is already being pushed.';
    case 'invalid_draft':
      return "The draft couldn't be validated. Check its recipients and subject.";
    case 'link_unsafe':
      return 'This draft file is not a regular file and cannot be pushed.';
    case 'no_credential':
      return 'Enter your mailbox password first.';
    case 'push_failed':
      return "The push failed before anything was sent. It's safe to try again.";
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'not_found':
      return 'This draft no longer exists.';
    default:
      return 'Could not push the draft. Check the account state and try again.';
  }
}

// -- send (spec G §UI) --------------------------------------------------------
//
// The confirm modal renders EXCLUSIVELY from the review snapshot — the
// drafts list's own parse is display-only and never reaches this function.

const NEW_THREAD_WARNING =
  "The message this replies to isn't mirrored here, so this will start a new thread.";

/**
 * The confirm modal's summary lines: who this goes to, as what, from whom.
 * Cc/Bcc lines are omitted when empty (an empty "Bcc:" line reads like a
 * bug); the identity line is the config-owned `from_name <from>` plus the
 * account slug, because with several accounts configured "which mailbox is
 * this leaving from" is exactly the question a confirm step must answer.
 * The threading warning is appended last, only when the reply's reference
 * could not be resolved.
 */
export function sendConfirmSummary(review: MailDraftReview): string[] {
  const lines = [`To: ${addressListLine(review.recipients.to)}`];
  if (review.recipients.cc.length > 0) lines.push(`Cc: ${addressListLine(review.recipients.cc)}`);
  if (review.recipients.bcc.length > 0) lines.push(`Bcc: ${addressListLine(review.recipients.bcc)}`);
  lines.push(`Subject: ${review.subject.trim() || '(no subject)'}`);

  const identity = addressLabel({ name: review.identity.fromName, email: review.identity.from });
  lines.push(`From: ${identity || '(no sending identity configured)'} · ${review.identity.account}`);

  if (review.threadingWarning) lines.push(NEW_THREAD_WARNING);
  return lines;
}

function addressListLine(list: { name: string | null; email: string }[]): string {
  return list.map((addr) => addressLabel(addr)).join(', ');
}

/**
 * What a send parked in `send_review` actually means, from its ledger notice
 * (spec G §Send pipeline 3-4). Two cases, and the difference matters:
 *
 *  - `gmail_sent_checked_empty` — Gmail's Sent Mail WAS searched for this
 *    message's id over a bounded window and came back empty. Strong evidence
 *    of a non-delivery, though not proof (Sent Mail visibility after a 250 is
 *    not guaranteed instant).
 *  - anything else (`send_unknown: …`, or no notice yet) — NOTHING has been
 *    checked, and the copy says exactly that.
 *
 * The fallback deliberately claims no reconciliation state of any kind. It
 * covers both profiles and the notice alone cannot tell them apart: a generic
 * (non-Gmail) account is never reconciled — there is no automatic search for
 * it, ever — so wording it as "still reconciling / awaiting a mailbox
 * connection" would be false for that account even while its mailbox syncs
 * perfectly, at the exact moment the user is deciding whether mail went out.
 * A gmail account that hasn't been reconciled yet is covered by the same
 * sentence, truthfully: nothing has been checked.
 *
 * Both end on the same instruction, because the resolution is the same act:
 * look in your own Sent folder and tell Valea what you found.
 */
export function sendReviewExplanation(notice: string | null): string {
  const check = 'Check your own Sent folder (and, if in doubt, the recipient), then tell Valea what you found.';

  if (notice === 'gmail_sent_checked_empty') {
    return `Sent Mail was checked and found empty — this message most likely did not go out. ${check}`;
  }

  return `The server never confirmed this send, and nothing has been checked automatically. ${check}`;
}

/**
 * The confirm modal's error + drift-gate state. `reloadable: true` means the
 * server has REFUSED the review currently on screen, so the confirm button is
 * withheld until a fresh review actually arrives — re-offering Send against a
 * refused review is offering a click that cannot succeed.
 */
export type SendGate = { error: string | null; reloadable: boolean };

/** Nothing wrong, Send armed — the modal's opening state, and the state a successful reload restores. */
export const SEND_GATE_CLEAR: SendGate = { error: null, reloadable: false };

/**
 * State after a send attempt failed. The two DRIFT refusals
 * (`re_review_required`, `content_changed`) are the only ones a reload fixes,
 * and both are pre-transmit: nothing was sent.
 */
export function sendGateAfterSendFailure(code: string): SendGate {
  return {
    error: sendErrorMessage(code),
    reloadable: code === 're_review_required' || code === 'content_changed'
  };
}

/**
 * State after a RELOAD attempt failed. It swaps in the fetch's own error but
 * carries `reloadable` through untouched — a failed reload leaves the refused
 * review exactly as refused, so dropping the gate here would re-arm Send on
 * a review the server has already rejected. This function can only ever
 * preserve the gate, never open one.
 */
export function sendGateAfterReloadFailure(gate: SendGate, code: string): SendGate {
  return { error: sendErrorMessage(code), reloadable: gate.reloadable };
}

/**
 * Error copy for the send flow (`get_mail_draft_review` / `send_draft` /
 * `resolve_send_review` / `retry_sent_copy`). The two drift codes
 * (`re_review_required`, `content_changed`) name the fix — reload the review
 * — because that is exactly one click away in the modal, and both are
 * pre-transmit refusals: nothing was sent.
 */
export function sendErrorMessage(code: string): string {
  switch (code) {
    case 're_review_required':
      return 'The sending identity or the thread changed while you were reviewing. Reload the review, then confirm again.';
    case 'content_changed':
      return 'The draft changed since you opened it. Reload the review, then send.';
    case 'draft_too_large':
      return 'This draft is too large to send.';
    case 'smtp_not_configured':
      return 'Add SMTP details for this account before sending.';
    case 'no_smtp_credential':
      return 'Enter your SMTP password first.';
    case 'not_reviewable':
      return 'This send was already resolved.';
    case 'not_retryable':
      return 'There is nothing left to retry for this message.';
    case 'duplicate_active':
      return 'This draft already has a push or a send in flight.';
    case 'invalid_draft':
      return "The draft couldn't be validated. Check its recipients and subject.";
    case 'link_unsafe':
      return 'This draft file is not a regular file and cannot be sent.';
    case 'status_forged':
      return 'This draft claims a status nothing corroborates. Reload it, then try again.';
    case 'not_found':
      return 'This draft no longer exists.';
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    default:
      return 'Could not send the draft. Check the account state and try again.';
  }
}

/**
 * Whether a row may offer Send (spec G §UI): a parseable draft whose PRIMARY
 * state is `draft`, on an account with a loadable `smtp:` block. The `pushed`
 * badge is deliberately not consulted — it is a fact beside the state, not a
 * state, so a pushed-then-edited draft stays sendable. A missing SMTP secret
 * does NOT hide the button: the backend answers `no_smtp_credential`, which
 * tells the user what to do; hiding it would just look broken.
 */
export function canSendDraft(
  draft: Pick<MailDraft, 'statusDisplay' | 'recipients'>,
  status: Pick<MailAccountStatus, 'smtpConfigured'> | null
): boolean {
  if (!status?.smtpConfigured) return false;
  if (draft.statusDisplay !== 'draft') return false;
  return !('invalid' in draft.recipients);
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

/**
 * The `/mail` link for one message row, ACCOUNT-QUALIFIED: a `msgId` is only
 * unique within its account, so a bare `?message=` link means "this id, in
 * whichever account happens to be selected when the link is opened". Naming
 * the account makes a copied/bookmarked/back-button link reopen the message
 * it actually points at, and lets the route select the right account first.
 */
export function messageHref(account: string, msgId: string): string {
  return `/mail?account=${encodeURIComponent(account)}&message=${encodeURIComponent(msgId)}`;
}

/**
 * Where the account switcher navigates. Switching accounts is a NAVIGATION,
 * not a store write: `?account=` is what the route reads to decide which
 * mailbox it is showing, and `mailStore.selectedAccount` is a tracked
 * dependency of that selection effect. Writing the store here would re-run
 * the effect against the not-yet-updated URL — which still names the OLD
 * account — and switch straight back. The URL leads; the store follows.
 *
 * Any open `?message=` is dropped (a msg id belongs to the account it was
 * opened from); `?drafts=1` survives, since that panel spans accounts.
 */
export function accountSwitchHref(url: URL, slug: string): string {
  const params = new URLSearchParams({ account: slug });
  if (url.searchParams.get('drafts') === '1') params.set('drafts', '1');
  return `/mail?${params.toString()}`;
}

/**
 * Which account the `/mail` view should be reading. The URL leads —
 * `?account=` names the account a link was written for — but only while it
 * still names a configured account: an unknown slug (a removed account, a
 * stale bookmark) falls back to the store's own selection instead of pointing
 * the app at a mailbox that isn't there. Before the account list has loaded
 * nothing can be checked, so the link is taken at its word.
 */
export function targetAccount(
  accParam: string | null,
  storeAccount: string | null,
  accounts: Pick<MailAccountStatus, 'account'>[]
): string | null {
  if (accParam === null) return storeAccount;
  if (accounts.length === 0) return accParam;
  return accounts.some((a) => a.account === accParam) ? accParam : storeAccount;
}

/**
 * The read pane's meta detail for a message's placement: comma-joined
 * `folders` frontmatter plus the maildir flag letters when present —
 * `"INBOX, Archive · flags: S"`. Replaces the deleted review/processed
 * `status` marker in `MessageView`'s meta line. Empty string when the
 * frontmatter carries neither (the meta line simply omits it).
 */
export function folderFlagsLine(frontmatter: Record<string, unknown> | null | undefined): string {
  if (!frontmatter) return '';
  const folders = Array.isArray(frontmatter.folders)
    ? frontmatter.folders.filter((f): f is string => typeof f === 'string' && f.length > 0)
    : [];
  const flags = typeof frontmatter.flags === 'string' ? frontmatter.flags.trim() : '';

  const parts = [];
  if (folders.length > 0) parts.push(folders.join(', '));
  if (flags) parts.push(`flags: ${flags}`);
  return parts.join(' · ');
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

/** Just the display name of an address ("" when absent) — the read-pane header renders name and email as separate pieces. */
export function addressName(addr: RawAddress): string {
  if (!addr || typeof addr !== 'object') return '';
  return typeof addr.name === 'string' ? addr.name.trim() : '';
}

/** Just the email of an address ("" when absent) — counterpart of `addressName`. */
export function addressEmail(addr: RawAddress): string {
  if (!addr || typeof addr !== 'object') return '';
  return typeof addr.email === 'string' ? addr.email.trim() : '';
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
    case 'identity_mismatch':
      return 'Folder belongs to a different account';
    case 'mailbox_replaced':
      return 'Mailbox replaced, needs re-adopt';
    case 'invalid_config':
      return 'Invalid configuration';
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
export function syncErrorText(status: MailAccountStatus | null, requestError: string | null): string | null {
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

// -- SetupPanel: account-setup submit flow (mail design spec, §Account
// setup + doctor / §Credentials) --------------------------------------------
//
// `submitMailSetup` is the ONE place that decides the desktop-vs-browser
// sequencing; `SetupPanel.svelte` just wires it to the real `api`,
// `keychain.ts`, and `mailStore` — same "extract the orchestration into a
// plain function so it's unit-testable without a component render harness"
// split this module already uses for `SyncStatusLine`'s `onSyncNow`.

export type MailSetupApi = Pick<Api, 'setupMailAccount' | 'setMailCredential'>;

export type MailSetupFormInput = {
  /** The account SLUG — a real form field now (validated against `MAIL_SLUG_RE` before any RPC), not derived from a label. */
  account: string;
  host: string;
  port: number;
  username: string;
  /** The typed password. Component-local `$state`, never a store field — see `SetupPanel.svelte`. */
  secret: string;
  generation: number;
  /** The optional SMTP block (spec G). Absent/`null` = a push-only account. */
  smtp?: MailSetupSmtpInput | null;
};

/**
 * The SMTP fieldset as the form holds it. `port`/`security` may be "not
 * supplied" (`null` / `''`) — the backend then applies its own convention
 * (587 → STARTTLS, 465 → TLS), which is why blank is a real, valid state
 * here rather than something to fill in client-side.
 */
export type MailSetupSmtpInput = {
  host: string;
  port: number | null;
  security: '' | 'starttls' | 'tls';
  username: string;
  /** Blank = default to `username` backend-side (only valid when that IS an address — see `smtpFormError`). */
  from: string;
  fromName: string;
  /** The typed SMTP password; ignored (and allowed to be blank) when `sameAsImap`. */
  secret: string;
  /** "Same as IMAP" — COPIES the IMAP secret into the `<slug>:smtp` entry (a copy, not an alias). */
  sameAsImap: boolean;
};

/**
 * The addr-spec grammar, mirrored client-side from
 * `Valea.Mail.DraftFile.@addr_re` (dot-atom local part, `@`, dotted
 * alnum/hyphen domain) — deliberately conservative, and structurally
 * rejecting whitespace and angle brackets, so `"Mara <mara@x>"` is not an
 * addr-spec. Used only to pre-empt the reason-free `invalid_smtp`; the
 * backend remains the authority.
 */
export const MAIL_ADDR_RE =
  /^[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+(\.[A-Za-z0-9!#$%&'*+/=?^_`{|}~-]+)*@[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$/;

/**
 * Everything about the SMTP fieldset that can be judged without a round
 * trip, in the order the fields appear. This exists because
 * `setup_mail_account` answers a REASON-FREE `"invalid_smtp"` (the settings
 * parser's message is deliberately not leaked through the RPC), so without
 * this a typo'd port/security pair would be a dead end.
 *
 * The rules mirror `Valea.Mail.Settings.parse_smtp/1` exactly:
 * host/username required; positive port; the 587↔STARTTLS / 465↔TLS
 * convention (other ports allowed, but must state `security`); `from`
 * defaulting to `username` and required to be a single addr-spec — so a
 * bare (non-email) login MUST supply an explicit From; and no CR/LF/NUL in
 * the display name. Returns the message to show, or `null` when nothing is
 * wrong. Not a substitute for the backend check — a pre-emption of it.
 */
export function smtpFormError(smtp: MailSetupSmtpInput): string | null {
  const host = smtp.host.trim();
  const username = smtp.username.trim();
  const from = smtp.from.trim();

  if (!host) return 'Enter the SMTP server host.';
  if (!username) return 'Enter the SMTP username.';
  if (smtp.port !== null && (!Number.isFinite(smtp.port) || smtp.port <= 0)) return 'Enter a valid SMTP port.';

  const port = smtp.port ?? 587;
  if (smtp.security === 'tls' && port === 587) {
    return 'Port 587 uses STARTTLS. Pick STARTTLS, or use port 465 for TLS.';
  }
  if (smtp.security === 'starttls' && port === 465) {
    return 'Port 465 uses TLS. Pick TLS, or use port 587 for STARTTLS.';
  }
  if (smtp.security === '' && port !== 587 && port !== 465) {
    return 'Pick a security setting — only ports 587 and 465 have a default.';
  }

  if (!from && !MAIL_ADDR_RE.test(username)) {
    return 'This username is not an email address, so enter the From address to send as.';
  }
  if (from && !MAIL_ADDR_RE.test(from)) {
    return 'From must be a single email address, like you@example.com.';
  }
  if (/[\r\n\0]/.test(smtp.fromName)) return 'The display name cannot contain line breaks.';
  if (!smtp.sameAsImap && !smtp.secret) return 'Enter the SMTP password.';

  return null;
}

/** The wire shape of the optional smtp block — blank fields become `null` ("not supplied"), never `""`. */
function smtpSetupArgs(smtp: MailSetupSmtpInput | null | undefined): MailSmtpSetup | null {
  if (!smtp) return null;
  return {
    host: smtp.host.trim(),
    port: smtp.port,
    security: smtp.security || null,
    username: smtp.username.trim(),
    from: smtp.from.trim() || null,
    fromName: smtp.fromName.trim() || null
  };
}

export type MailSetupDeps = {
  api: MailSetupApi;
  inDesktop: () => boolean;
  /**
   * Refreshes mail status and resolves the just-reloaded `workspaceId` (or
   * `null` if it still isn't available). Deliberately a fetch-and-return
   * closure, not a read of some already-cached value: this may be the
   * workspace's very first mail config, so the only `workspaceId` this
   * function can trust is one re-fetched AFTER `setupMailAccount` has
   * already landed — see the doc comment on `submitMailSetup` below.
   */
  refreshWorkspaceId: () => Promise<string | null>;
  keychainSet: (workspaceId: string, username: string, secret: string) => Promise<boolean>;
};

export type MailSetupOutcome = { ok: true; devMode: boolean } | { ok: false; error: string };

/**
 * Orchestrates the account-setup submit flow: client-side slug validation
 * first (no RPC on a slug the backend would reject anyway), then
 * `setupMailAccount` (writes `config/mail.yaml`), then hands the password
 * off over whichever channel the platform allows.
 *
 * Desktop: `refreshWorkspaceId()` is called (and awaited) AFTER
 * `setupMailAccount` succeeds and BEFORE `keychainSet` — never a
 * caller-cached status value, since this may be the first mail config the
 * workspace has ever had. The keychain entry is keyed `<slug>:imap` (the
 * account slug, not the IMAP login — matches `resupplyCredentials`'s read
 * key in `stores/mail.svelte.ts`; slugs are unique per workspace, logins
 * need not be). `keychainSet` is best-effort (mirrors `keychain.ts`'s own
 * contract: it never throws, and a `false`/skipped result never blocks the
 * RPC handoff below — a failed local keychain write just means recovery
 * won't silently resupply after the next restart).
 *
 * Browser (dev): skips the keychain entirely and goes straight to
 * `setMailCredential`; the caller renders the "not persisted" note off
 * `devMode: true`.
 *
 * SMTP (spec G) rides the same sequencing, one slot later: its secret goes
 * to the SEPARATE `<slug>:smtp` keychain entry and over `setMailCredential`
 * with `kind: 'smtp'`. "Same as IMAP" COPIES the typed IMAP secret into that
 * entry — a copy, not an alias, so the two rotate independently.
 *
 * Either path short-circuits with `{ ok: false, error }` the moment
 * `setupMailAccount` or either `setMailCredential` fails — the raw error
 * code from the RPC (map it with `mailSetupErrorMessage` for display). An
 * `invalid_smtp` refusal therefore hands NO secret to anything: the account
 * wasn't written, so there is nothing to supply a credential to.
 */
export async function submitMailSetup(input: MailSetupFormInput, deps: MailSetupDeps): Promise<MailSetupOutcome> {
  const slug = input.account;
  if (!mailSlugValid(slug)) return { ok: false, error: 'invalid_slug' };

  const setupResult = await deps.api.setupMailAccount(
    slug,
    input.host,
    input.port,
    input.username,
    input.generation,
    smtpSetupArgs(input.smtp)
  );
  if (!setupResult.ok) return { ok: false, error: setupResult.error };

  const smtpSecret = input.smtp ? (input.smtp.sameAsImap ? input.secret : input.smtp.secret) : null;
  const desktop = deps.inDesktop();

  if (desktop) {
    const workspaceId = await deps.refreshWorkspaceId();
    if (workspaceId) {
      await deps.keychainSet(workspaceId, `${slug}:imap`, input.secret);
      if (smtpSecret !== null) await deps.keychainSet(workspaceId, `${slug}:smtp`, smtpSecret);
    }
  }

  const credResult = await deps.api.setMailCredential(slug, input.secret, input.generation);
  if (!credResult.ok) return { ok: false, error: credResult.error };

  if (smtpSecret !== null) {
    const smtpResult = await deps.api.setMailCredential(slug, smtpSecret, input.generation, 'smtp');
    if (!smtpResult.ok) return { ok: false, error: smtpResult.error };
  }

  return { ok: true, devMode: !desktop };
}

/** Same error-code vocabulary as `syncNowErrorMessage` (both actions are gated by `Manager.check_generation/1`). */
export function mailSetupErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'invalid_slug':
      return 'Account id must be lowercase letters, digits, and dashes (up to 32 characters).';
    case 'identity_mismatch':
      return 'A different account already owns this folder on disk. Purge it first from the account list.';
    case 'invalid_smtp':
      // Reason-free by design (the settings parser's message isn't leaked
      // through the RPC), so this names the fields rather than the fault —
      // `smtpFormError` catches everything checkable before we get here.
      return 'The SMTP details were rejected. Check the host, port, security, and From address.';
    default:
      return 'Could not save your mail account. Check the details and try again.';
  }
}

/**
 * Error copy for the account-maintenance actions (`remove_mail_account`,
 * `purge_mail_account_files`, `readopt_mail_account`,
 * `discard_held_folder`) — `Valea.Api.Mail.error_for/1`'s vocabulary for
 * those actions, over the same generation-guard codes as everything else.
 */
export function mailMaintenanceErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'confirmation_mismatch':
      return "The confirmation text doesn't match.";
    case 'account_active':
      return 'This account is still running. Remove it from the config first, or wait for it to stop.';
    case 'not_held':
      return 'That folder is not held anymore.';
    case 'mailbox_replaced':
      return 'This account is blocked pending re-adopt.';
    case 'not_found':
      return 'No such account.';
    default:
      return 'The action failed. Check the account state and try again.';
  }
}

// -- MailDoctorPanel: check-row shaping (backend: `Valea.Mail.Doctor.run/1`,
// `mail_doctor`'s `checks` field — UNCONSTRAINED `:map`, see
// `Valea.Api.Mail`'s moduledoc, so it arrives as loosely-typed
// `Record<string, any>[]` and must be narrowed defensively, same posture as
// `attachmentsFromFrontmatter` above) ----------------------------------------

export type MailDoctorCheck = {
  id: string;
  label: string;
  status: string;
  detail: string;
  remedy: string | null;
};

/** Narrows `mail_doctor`'s raw `checks` payload; an entry with no `id` is dropped rather than rendered as a mystery row. */
export function normalizeMailDoctorChecks(raw: unknown): MailDoctorCheck[] {
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((entry): MailDoctorCheck[] => {
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

/** Gates the "Create folders" button (`Valea.Mail.Doctor`'s `folders` check id) — visible only once it has actually failed, not while gated `"unknown"` behind an earlier check. */
export function foldersCheckFailed(checks: MailDoctorCheck[]): boolean {
  return checks.some((check) => check.id === 'folders' && check.status === 'failed');
}

// -- MailDoctorPanel: "Create folders" sequencing -----------------------------
//
// Same extraction rationale as `submitMailSetup`: the create-then-recheck
// ordering (and its error/flag handling) is the testable part, so it lives
// here as a plain function over injected deps; `MailDoctorPanel.svelte`
// wires it to the real `api`, its own `run()` and its `creatingFolders`
// flag.

export type CreateFoldersDeps = {
  api: Pick<Api, 'createMailFolders'>;
  /** The panel's own doctor run — re-invoked after a successful create so the folder rows reflect reality. */
  rerunDoctor: () => Promise<void>;
  /** The panel's in-flight flag setter. Guaranteed to be called with `false` again on EVERY exit path, including a thrown step. */
  setBusy: (busy: boolean) => void;
};

/**
 * "Create folders" (backend: `Valea.Mail.Engine.create_folders/1` via
 * `api.createMailFolders`): flips busy on, creates the missing configured
 * special folders, and — only if that RPC actually succeeded — re-runs the doctor
 * so the `folders` row updates. A failed create resolves the mapped
 * display message (see `createFoldersErrorMessage`) and deliberately skips
 * the re-run: nothing changed server-side, so the checks on screen are
 * still accurate. The busy flag is reset in a `finally`, so even a step
 * that throws (none should — `ApiResult` calls never throw by contract)
 * can't strand the button in its disabled "Creating…" state.
 */
export async function createFoldersAndRecheck(
  deps: CreateFoldersDeps,
  account: string,
  generation: number
): Promise<string | null> {
  deps.setBusy(true);
  try {
    const result = await deps.api.createMailFolders(account, generation);
    if (!result.ok) return createFoldersErrorMessage(result.error);

    await deps.rerunDoctor();
    return null;
  } finally {
    deps.setBusy(false);
  }
}

/**
 * `create_mail_folders`'s error vocabulary: the generation guard's
 * `workspace_not_open`/`workspace_changed` plus `Engine.create_folders/0`'s
 * own gate (`inactive | not_configured | no_credential` — the same
 * `validate_sync/1` gate as `sync_now`). `inactive` means no workspace
 * runtime is up, which the user experiences identically to
 * `workspace_not_open`. Anything else (a connect failure's inspected
 * reason term, passed through `error_for/1`) gets the generic fallback.
 */
export function createFoldersErrorMessage(code: string): string {
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
      return 'Could not create the folders. Check the connection and try again.';
  }
}

// -- MessageView: "Start a session about this message" (Spec D §B/§E) --------
//
// Replaces the deleted "Run triage" workflow action. `api.createAgentSession`
// grants the session read access to exactly ONE file via `opts.input`
// (`{kind: 'workspace', path: message.path}`) and echoes the resolved
// absolute path back as `inputPath` — same "opening prompt names the exact
// path the session was granted" convention as `initial-prompt.ts`'s
// `pageSessionPrompt` (Knowledge's "Start a session with this page").

/**
 * Opening prompt for a mail-message session — `inputPath` is the resolved
 * absolute path `createAgentSession` echoed back (falls back to the
 * pre-resolve `message.path` if that's ever null); `mailMountKey` is the
 * account's `mail-<slug>` mount the session was opted into via
 * `includeMounts`.
 */
export function messageSessionPrompt(inputPath: string, mailMountKey: string): string {
  return [
    `Read the mail message at \`${inputPath}\` — the whole account is also mounted read-only as \`${mailMountKey}\`.`,
    `Summarize who it's from and what they need, then help me decide how to handle it.`,
    `To act on the mailbox (archive, move, flag), write a YAML ops file into the mount's ops/pending/ (vocabulary: move, flag) — the engine validates and executes it; never modify maildir/ directly.`,
    `If a reply is warranted, write a draft file under the mount's drafts/ — you cannot send anything; only I can push a draft to the mailbox.`
  ].join(' ');
}
