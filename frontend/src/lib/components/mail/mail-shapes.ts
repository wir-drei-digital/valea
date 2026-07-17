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

import type { MailAccountStatus, MailDraft, MailFolder } from '$lib/stores/mail.svelte';
import type { Api } from '$lib/api/client';

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
      return 'The message changed on the server — sync and try again.';
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

/** Error copy for a failed push (`push_draft_to_mailbox` / `get_mail_draft` error codes). */
export function pushErrorMessage(code: string): string {
  switch (code) {
    case 'content_changed':
      return 'The draft changed since you opened it — review it again, then push.';
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
      return 'Mailbox replaced — needs re-adopt';
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
};

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
 * Either path short-circuits with `{ ok: false, error }` the moment
 * `setupMailAccount` or `setMailCredential` itself fails — the raw error
 * code from the RPC (map it with `mailSetupErrorMessage` for display).
 */
export async function submitMailSetup(input: MailSetupFormInput, deps: MailSetupDeps): Promise<MailSetupOutcome> {
  const slug = input.account;
  if (!mailSlugValid(slug)) return { ok: false, error: 'invalid_slug' };

  const setupResult = await deps.api.setupMailAccount(slug, input.host, input.port, input.username, input.generation);
  if (!setupResult.ok) return { ok: false, error: setupResult.error };

  if (deps.inDesktop()) {
    const workspaceId = await deps.refreshWorkspaceId();
    if (workspaceId) {
      await deps.keychainSet(workspaceId, `${slug}:imap`, input.secret);
    }

    const credResult = await deps.api.setMailCredential(slug, input.secret, input.generation);
    if (!credResult.ok) return { ok: false, error: credResult.error };
    return { ok: true, devMode: false };
  }

  const credResult = await deps.api.setMailCredential(slug, input.secret, input.generation);
  if (!credResult.ok) return { ok: false, error: credResult.error };
  return { ok: true, devMode: true };
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
