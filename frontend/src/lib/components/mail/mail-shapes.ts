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
import type { Api } from '$lib/api/client';

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
 * Orchestrates the account-setup submit flow: `setupMailAccount` first
 * (writes `config/mail.yaml`), then hands the password off over whichever
 * channel the platform allows.
 *
 * Desktop: `refreshWorkspaceId()` is called (and awaited) AFTER
 * `setupMailAccount` succeeds and BEFORE `keychainSet` — never a
 * caller-cached status value, since this may be the first mail config the
 * workspace has ever had. The keychain entry's `username`, by contrast,
 * comes from `input.username` (the FORM value, i.e. exactly what was just
 * typed and just saved) rather than from any refreshed status field — that
 * value is trustworthy the instant `setupMailAccount` resolves, with no
 * refetch needed. `keychainSet` is best-effort (mirrors `keychain.ts`'s own
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
  const setupResult = await deps.api.setupMailAccount(
    input.account,
    input.host,
    input.port,
    input.username,
    input.generation
  );
  if (!setupResult.ok) return { ok: false, error: setupResult.error };

  if (deps.inDesktop()) {
    const workspaceId = await deps.refreshWorkspaceId();
    if (workspaceId) {
      await deps.keychainSet(workspaceId, input.username, input.secret);
    }

    const credResult = await deps.api.setMailCredential(input.secret, input.generation);
    if (!credResult.ok) return { ok: false, error: credResult.error };
    return { ok: true, devMode: false };
  }

  const credResult = await deps.api.setMailCredential(input.secret, input.generation);
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
    default:
      return 'Could not save your mail account. Check the details and try again.';
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

/** Gates the "Create AI folders" button (`Valea.Mail.Doctor`'s `folders` check id) — visible only once it has actually failed, not while gated `"unknown"` behind an earlier check. */
export function foldersCheckFailed(checks: MailDoctorCheck[]): boolean {
  return checks.some((check) => check.id === 'folders' && check.status === 'failed');
}

// -- MailDoctorPanel: "Create AI folders" sequencing --------------------------
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
 * "Create AI folders" (backend: `Valea.Mail.Engine.create_folders/0` via
 * `api.createMailFolders`): flips busy on, creates the missing AI/*
 * folders, and — only if that RPC actually succeeded — re-runs the doctor
 * so the `folders` row updates. A failed create resolves the mapped
 * display message (see `createFoldersErrorMessage`) and deliberately skips
 * the re-run: nothing changed server-side, so the checks on screen are
 * still accurate. The busy flag is reset in a `finally`, so even a step
 * that throws (none should — `ApiResult` calls never throw by contract)
 * can't strand the button in its disabled "Creating…" state.
 */
export async function createFoldersAndRecheck(deps: CreateFoldersDeps, generation: number): Promise<string | null> {
  deps.setBusy(true);
  try {
    const result = await deps.api.createMailFolders(generation);
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
