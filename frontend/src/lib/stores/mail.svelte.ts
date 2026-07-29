import { api, type Api } from '../api/client';
import { workspaceStore } from './workspace.svelte';
import { sha256Hex } from '../components/mail/mail-shapes';
import { inDesktop, keychainGet } from '../keychain';
import type { MailStatusPush, MailSyncPush, MailMessagePush, MailDraftPush } from '../socket';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as the other stores, so tests can inject a fake without
 * implementing every wrapped call. `setMailCredential` is included even
 * though no `MailStore` method calls it directly — the status paths forward
 * this same injected api into the module-level `resupplyCredentials` helper
 * below rather than reaching for the `api` singleton, so a store built with
 * a fake api never has a side effect leak out through the real one.
 */
type MailApi = Pick<
  Api,
  | 'mailStatus'
  | 'listMailFolders'
  | 'listMailMessages'
  | 'getMailMessage'
  | 'mailSyncNow'
  | 'setMailCredential'
  | 'applyMailOps'
  | 'listMailDrafts'
  | 'getMailDraft'
  | 'pushDraftToMailbox'
  | 'getMailDraftReview'
  | 'sendDraft'
  | 'resolveSendReview'
  | 'retrySentCopy'
>;

const INBOX_FOLDER = 'INBOX';

/**
 * How many rows one `list_mail_messages` call asks for. Passed EXPLICITLY on
 * every call rather than left to the action's own identical default, because
 * pagination reads the page size back out of the response: a page that comes
 * back SHORT is the end of the folder, and only a full one can have anything
 * behind it.
 */
export const MAIL_PAGE_SIZE = 100;

/**
 * One account's app-facing status — camelCased/typed from the raw per-account
 * entry of `mail_status`'s `accounts` list (and, identically shaped minus
 * `valid`/`reason`, the `mail_status` channel push — see `MailStatusPush`'s
 * doc comment in `socket.ts`). An invalid-config entry (`valid: false`)
 * carries only `account`/`state: "invalid_config"`/`reason`; every engine
 * field degrades to its empty default for those.
 */
export type MailAccountStatus = {
  account: string;
  valid: boolean;
  /** Invalid-config explanation (`valid: false` entries only); `null` on every valid account. */
  reason: string | null;
  configured: boolean;
  credential: 'present' | 'missing';
  state: string;
  lastSyncAt: string | null;
  lastError: string | null;
  /** IMAP login (`imap.username`) — display/form value only; the OS-keychain key is slug-based (see `resupplyCredentials`). */
  username: string | null;
  workspaceId: string | null;
  pendingOps: number;
  heldFolders: string[];
  notices: string[];
  /**
   * The account's configured special-folder names (`drafts`/`sent`/
   * `archive`/`trash` — Gmail's archive is `"[Gmail]/All Mail"`, never
   * `"Archive"`); `null` until the engine has settings. The archive action
   * composes its move op from these, never from a hardcoded name.
   */
  folders: Record<string, string> | null;
  /** Whether the account has a loadable `smtp:` block (spec G) — the gate on every Send affordance. */
  smtpConfigured: boolean;
  /** The SMTP credential slot: `"n/a"` for a push-only account, which is NOT the same as a missing secret. */
  smtpCredential: 'present' | 'missing' | 'n/a';
};

/** One folder of `list_mail_folders` — camelCased per-item typed map (`ListMailFoldersFields` in `api/client.ts`). */
export type MailFolder = {
  name: string;
  dir: string | null;
  held: boolean;
  messageCount: number;
  backfillComplete: boolean;
};

/**
 * One row of `list_mail_messages` — mirrors `listMailMessagesFields` in
 * `api/client.ts`. `flags` is the maildir flag-letter string (e.g. `"S"`
 * for Seen); `viewPath` the derived view's workspace-relative path.
 */
export type MailMessageSummary = {
  msgId: string;
  fromName: string | null;
  fromEmail: string | null;
  subject: string | null;
  date: string | null;
  flags: string | null;
  hasAttachments: boolean;
  uid: number | null;
  path: string | null;
  viewPath: string;
};

/**
 * `get_mail_message`'s result — the parsed message view file, plus the
 * sanitized HTML rendering (`null` when the message has no usable
 * text/html part) and the remote-content trust gate the read pane's banner
 * keys off (`Valea.Mail.Trust`).
 */
export type MailMessageDetail = {
  frontmatter: Record<string, unknown> | null;
  body: string;
  path: string;
  html: string | null;
  externalContent: boolean;
  senderTrusted: boolean;
};

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

function strings(v: unknown): string[] {
  return Array.isArray(v) ? v.filter((s): s is string => typeof s === 'string') : [];
}

/**
 * Normalizes one raw account entry (RPC `accounts` item or a `mail_status`
 * channel push — both carry the identical snake_case shape) into the
 * camelCase `MailAccountStatus` app shape. `credential` is defensively
 * narrowed to the closed union rather than trusted as-is, mirroring
 * `normalizeIcmNode`'s guard in `icm.svelte.ts`. `valid` defaults to `true`
 * when absent — channel pushes only ever come from a live engine, and the
 * RPC marks only the broken entries with `valid: false`.
 *
 * `smtp_configured`/`smtp_credential` ride STRING keys on the engine's
 * status map (the falsy-map-field rule documented on `Valea.Mail.Engine`'s
 * `@type status` — ash_typescript nulls a top-level atom-keyed field whose
 * value is `false`), which changes nothing here: `accounts` is delivered
 * raw, so every entry field arrives snake_cased either way.
 */
export function normalizeMailAccountStatus(raw: Record<string, unknown>): MailAccountStatus {
  return {
    account: str(raw.account) ?? '',
    valid: raw.valid !== false,
    reason: str(raw.reason),
    configured: raw.configured === true,
    credential: raw.credential === 'present' ? 'present' : 'missing',
    state: str(raw.state) ?? 'inactive',
    lastSyncAt: str(raw.last_sync_at),
    lastError: str(raw.last_error),
    username: str(raw.username),
    workspaceId: str(raw.workspace_id),
    pendingOps: typeof raw.pending_ops === 'number' ? raw.pending_ops : 0,
    heldFolders: strings(raw.held_folders),
    notices: strings(raw.notices),
    folders: normalizeFolderNames(raw.folders),
    smtpConfigured: raw.smtp_configured === true,
    smtpCredential: smtpCredentialState(raw.smtp_credential)
  };
}

/**
 * Narrows the SMTP credential slot to its closed union. Anything that isn't
 * one of the two real states degrades to `"n/a"` — "this account has no
 * `smtp:` block", the safe reading: it gates the resupply path OFF rather
 * than sending a secret at an account that may not want one.
 */
function smtpCredentialState(raw: unknown): 'present' | 'missing' | 'n/a' {
  if (raw === 'present') return 'present';
  if (raw === 'missing') return 'missing';
  return 'n/a';
}

function normalizeFolderNames(raw: unknown): Record<string, string> | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const entries = Object.entries(raw as Record<string, unknown>).filter(
    (pair): pair is [string, string] => typeof pair[1] === 'string'
  );
  return entries.length > 0 ? Object.fromEntries(entries) : null;
}

/**
 * One draft of `list_mail_drafts` — normalized from the raw string-keyed
 * entry (`Valea.Api.Mail.draft_entry/3`). `statusDisplay` is LEDGER-derived
 * backend-side (`draft`/`pushing`/`pushed`/`sending`/`send_review`/`sent`/
 * `needs_review`/`rejected`); `recipients` is either the parsed
 * to/cc/bcc+subject or `{invalid}` for an unparseable/link-unsafe draft.
 *
 * `pushed` is a separate FACT, not a state (spec G §Display projection): any
 * completed append, rendered as a badge BESIDE the primary state and never
 * overriding it — Send and Push both key off the primary state alone.
 */
export type MailDraft = {
  account: string;
  name: string;
  path: string;
  statusDisplay: string;
  notice: string | null;
  /** Any completed push — a badge fact beside the primary state. */
  pushed: boolean;
  /**
   * The ledger op id a row's resolution actions act on (`resolve_send_review`
   * / `retry_sent_copy`). `null` whenever the row carries none, which the
   * resolution UI treats as "no actionable op": the actions are hidden rather
   * than fired at a guessed id.
   */
  opId: string | null;
  recipients:
    | { invalid: string }
    | {
        to: { name: string | null; email: string }[];
        cc: { name: string | null; email: string }[];
        bcc: { name: string | null; email: string }[];
        subject: string | null;
      };
};

function normalizeAddresses(raw: unknown): { name: string | null; email: string }[] {
  if (!Array.isArray(raw)) return [];
  return raw.flatMap((entry) => {
    if (!entry || typeof entry !== 'object') return [];
    const rec = entry as Record<string, unknown>;
    if (typeof rec.email !== 'string') return [];
    return [{ name: typeof rec.name === 'string' ? rec.name : null, email: rec.email }];
  });
}

export function normalizeMailDraft(raw: Record<string, unknown>): MailDraft {
  const parsed = (raw.parsed_recipients ?? {}) as Record<string, unknown>;
  const recipients =
    typeof parsed.invalid === 'string'
      ? { invalid: parsed.invalid }
      : {
          to: normalizeAddresses(parsed.to),
          cc: normalizeAddresses(parsed.cc),
          bcc: normalizeAddresses(parsed.bcc),
          subject: str(parsed.subject)
        };

  return {
    account: str(raw.account) ?? '',
    name: str(raw.name) ?? '',
    path: str(raw.path) ?? '',
    statusDisplay: str(raw.status_display) ?? 'draft',
    notice: str(raw.notice),
    pushed: raw.pushed === true,
    opId: str(raw.op_id),
    recipients
  };
}

/**
 * The `get_mail_draft_review` snapshot (spec G §UI): everything the confirm
 * modal renders AND both tokens it confirms with, all out of ONE backend-side
 * read of the draft (`OpsExecutor.review_snapshot/2`). Nothing shown to the
 * human may come from a different read than the hashes they confirm — which
 * is why the modal renders exclusively from this, never from the (display-
 * only) parse in the drafts list.
 *
 * `reviewFingerprint` is `null` exactly for a push-only account (no `smtp:`
 * block); it is passed back to `send_draft` VERBATIM, never re-derived here.
 */
export type MailDraftReview = {
  /** The raw draft bytes of that same buffer — the modal's body preview. */
  content: string;
  contentHash: string;
  reviewFingerprint: string | null;
  recipients: {
    to: { name: string | null; email: string }[];
    cc: { name: string | null; email: string }[];
    bcc: { name: string | null; email: string }[];
  };
  subject: string;
  /** The RESOLVED threading headers, or `null` when this isn't a reply (or the reference isn't mirrored). */
  threading: { inReplyTo: string; references: string[] } | null;
  /** True when an `in_reply_to` could not be resolved — the message will start a NEW thread. */
  threadingWarning: boolean;
  /** The config-owned sending identity. A draft can never set or override it. */
  identity: { from: string | null; fromName: string | null; account: string };
  smtpConfigured: boolean;
};

/**
 * Narrows the review payload: the action's TYPED fields arrive camelCased
 * (`contentHash`, `threadingWarning`, `reviewFingerprint`,
 * `smtpConfigured`), its three unconstrained nested maps keep the snake keys
 * `review_snapshot/2` writes (`in_reply_to`, `from_name`, …). Every field
 * degrades to a harmless default rather than throwing — same defensive
 * posture as `attachmentsFromFrontmatter`.
 */
export function normalizeMailDraftReview(raw: Record<string, unknown>): MailDraftReview {
  const recipients = (raw.recipients ?? {}) as Record<string, unknown>;
  const identity = (raw.identity ?? {}) as Record<string, unknown>;
  const threading = raw.threading as Record<string, unknown> | null | undefined;
  const inReplyTo = threading ? str(threading.in_reply_to) : null;

  return {
    content: str(raw.content) ?? '',
    contentHash: str(raw.contentHash) ?? '',
    reviewFingerprint: str(raw.reviewFingerprint),
    recipients: {
      to: normalizeAddresses(recipients.to),
      cc: normalizeAddresses(recipients.cc),
      bcc: normalizeAddresses(recipients.bcc)
    },
    subject: str(raw.subject) ?? '',
    threading: inReplyTo ? { inReplyTo, references: strings(threading?.references) } : null,
    threadingWarning: raw.threadingWarning === true,
    identity: {
      from: str(identity.from),
      fromName: str(identity.from_name),
      account: str(identity.account) ?? ''
    },
    smtpConfigured: raw.smtpConfigured === true
  };
}

/**
 * Live view of the configured mail accounts: the per-account status list,
 * the selected account's folder list, the selected folder's message list
 * (paginated — `loadOlder` appends the page behind the oldest loaded row,
 * and the live refetches re-read only the NEWEST page; see
 * `refreshMessages` for the compromise that buys), and the currently open
 * message's detail.
 *
 * `handleMailStatus`/`handleMailSync`/`handleMailMessage`/`handleMailDraft`
 * are plain public methods, not wired to a channel by this store itself —
 * per this codebase's established `workspace:events` convention (see
 * `wireIcmEvents` in `icm.svelte.ts`), only ONE `joinWorkspaceEvents` call
 * site may exist. All four payloads carry the account slug; the
 * folder/message refetches are FILTERED to the currently selected account (a
 * push for a background account only upserts its status row), so a busy
 * second account can't churn the list the user is actually reading. The
 * drafts refetch is deliberately NOT filtered — see `handleMailDraft`.
 */
export class MailStore {
  accounts: MailAccountStatus[] = $state([]);
  selectedAccount: string | null = $state(null);
  folders: MailFolder[] = $state([]);
  selectedFolder: string | null = $state(INBOX_FOLDER);
  messages: MailMessageSummary[] = $state([]);
  selected: MailMessageDetail | null = $state(null);
  drafts: MailDraft[] = $state([]);
  /**
   * In-flight flag for `select()` (the one async call heavy/slow enough —
   * it reads a whole message file — to warrant a UI spinner). The list
   * refreshes don't get their own flags: an empty `folders`/`messages`
   * array before the first successful refetch is an adequate "not loaded
   * yet" signal.
   */
  loading = $state(false);
  /**
   * Whether the OLDEST loaded page came back full — i.e. there may be older
   * messages behind it, and the list's "Load older" row has something to ask
   * for. False whenever the loaded rows yield no usable cursor (see
   * `#trackPagination`).
   */
  lastPageFull = $state(false);
  /** In-flight flag for `loadOlder()` — the "Load older" row disables on it. */
  loadingOlder = $state(false);

  #api: MailApi;

  /**
   * `list_mail_messages`' `before` cursor: the `date` of the oldest loaded
   * row, handed back VERBATIM. The backend filters `date < before` against
   * the same plain-string column it sorts on (`Valea.Mail.Store.list_messages/4`),
   * so the value round-trips without either side parsing it. `null` before
   * the first page lands, and whenever the loaded rows carry no date at all —
   * an undated message can't be reached through a date cursor, so pagination
   * stops there rather than re-reading the same page forever.
   *
   * Strictly-less is the backend's comparison, not a choice made here: a
   * message sharing the cursor's exact timestamp is skipped by the page
   * behind it. Nothing on this side can widen that without changing the
   * action.
   */
  #oldestCursor: string | null = null;

  /**
   * `mail_status` push subscribers beyond this store's own refetch reaction
   * (see `handleMailStatus` below) — `onMailStatus`'s doc comment explains
   * why these exist instead of routes opening their own `channel.on(...)`
   * bindings.
   */
  #mailStatusListeners = new Set<(payload: MailStatusPush) => void>();

  constructor(api: MailApi) {
    this.#api = api;
  }

  /** The selected account's own status row, or `null` when nothing is selected/known. */
  get selectedStatus(): MailAccountStatus | null {
    return this.accounts.find((a) => a.account === this.selectedAccount) ?? null;
  }

  async refreshStatus(): Promise<void> {
    const result = await this.#api.mailStatus();
    if (!result.ok) return;

    const data = result.data as { accounts?: unknown };
    const raw = Array.isArray(data.accounts) ? (data.accounts as Record<string, unknown>[]) : [];
    this.accounts = raw.map(normalizeMailAccountStatus);
    await this.#ensureSelection();
    void resupplyCredentials(this.accounts, this.#api);
  }

  /**
   * The selected account's drafts. `list_mail_drafts` is workspace-wide (it
   * returns every account's drafts in one list, which the Drafts panel wants),
   * so anything showing "the drafts" for the account being read — the pane's
   * count above all — has to narrow it here rather than use `drafts.length`.
   */
  get selectedDrafts(): MailDraft[] {
    return this.drafts.filter((draft) => draft.account === this.selectedAccount);
  }

  /**
   * Switches the UI to `slug`: resets the folder selection to INBOX, drops
   * the open message detail, and refetches folders + messages. A re-select
   * of the current account is a no-op.
   *
   * The folder/message lists are cleared SYNCHRONOUSLY, before the refetch:
   * otherwise the previous account's rows stay on screen for the whole
   * round-trip, under the new account's name — long enough to click a
   * message that belongs to the mailbox the user just switched away from.
   */
  async selectAccount(slug: string): Promise<void> {
    if (slug === this.selectedAccount) return;
    this.selectedAccount = slug;
    this.selectedFolder = INBOX_FOLDER;
    this.selected = null;
    this.folders = [];
    this.messages = [];
    this.#resetPagination();
    await Promise.all([this.refreshFolders(), this.refreshMessages()]);
  }

  async refreshFolders(): Promise<void> {
    const account = this.selectedAccount;
    if (!account) {
      this.folders = [];
      return;
    }

    const result = await this.#api.listMailFolders(account);
    if (!result.ok) return;

    const data = result.data as { folders?: MailFolder[] };
    this.folders = data.folders ?? [];
  }

  /** Switches the message list to `name` within the selected account — a folder switch starts over at page one. */
  async selectFolder(name: string): Promise<void> {
    this.selectedFolder = name;
    this.#resetPagination();
    await this.refreshMessages();
  }

  /**
   * Lists the selected folder of the selected account — a no-op that clears
   * `messages` when no account is known yet.
   *
   * This is also the LIVE path (every `mail_status`/`mail_sync`/`mail_message`
   * push lands here), so it re-fetches the NEWEST page only and merges it
   * over what's loaded: the fresh page replaces the head of the list
   * wholesale — new arrivals, deletions and flag changes inside it all show
   * up — while everything OLDER than that page (whatever `loadOlder`
   * appended) is kept as-is.
   *
   * That compromise is deliberate. Re-fetching every loaded page on every
   * push costs one RPC per page per sync tick; replacing the list with page
   * one alone would collapse a reader who had paged back through months of
   * mail down to the newest hundred, mid-scroll. The price is that an
   * appended older page doesn't refresh until the folder is re-entered — a
   * message deleted down there stays on screen that long, which is the
   * cheapest of the three wrong things.
   *
   * A SHORT page needs no merge: it means the folder holds fewer than
   * `MAIL_PAGE_SIZE` messages in total, so anything still held from an
   * earlier page is gone from the mailbox and must go from the list too.
   */
  async refreshMessages(): Promise<void> {
    const account = this.selectedAccount;
    if (!account) {
      this.messages = [];
      this.#resetPagination();
      return;
    }

    const result = await this.#api.listMailMessages(account, this.selectedFolder ?? INBOX_FOLDER, {
      limit: MAIL_PAGE_SIZE
    });
    if (!result.ok) return;

    const data = result.data as { messages?: MailMessageSummary[] };
    const page = data.messages ?? [];
    const pageFull = page.length >= MAIL_PAGE_SIZE;
    // Nothing to merge over before the first page of THIS folder has landed
    // (`#resetPagination` nulls the cursor on every switch) — without that
    // guard the previous folder's rows would splice into this one's list.
    const keepOlder = pageFull && this.#oldestCursor !== null;
    this.messages = keepOlder ? mergeNewestPage(page, this.messages) : page;
    // On the merge path the oldest loaded page is the kept TAIL's last one,
    // which this fetch says nothing about — carry its fullness forward.
    this.#trackPagination(keepOlder ? this.lastPageFull : pageFull);
  }

  /**
   * Appends the page of messages BEHIND the oldest loaded one — the list's
   * "Load older" row. A no-op unless the oldest loaded page came back full
   * (a short page is the end of the folder, and asking again would only
   * re-read what's already on screen) and while a call is already in flight.
   *
   * The account/folder are captured before the call and re-checked after it:
   * a switch landing mid-flight makes this response belong to a folder the
   * user is no longer reading, and appending it would splice one folder's
   * messages into another's list. The switch's own refetch has replaced the
   * list by then, so dropping the response costs nothing — including its
   * clearing of `loadingOlder`, which `#resetPagination` has already done
   * for the list now on screen (and which a newer call may now own).
   */
  async loadOlder(): Promise<void> {
    const account = this.selectedAccount;
    const folder = this.selectedFolder ?? INBOX_FOLDER;
    const before = this.#oldestCursor;
    if (!account || !before || !this.lastPageFull || this.loadingOlder) return;

    this.loadingOlder = true;
    const result = await this.#api.listMailMessages(account, folder, { limit: MAIL_PAGE_SIZE, before });
    if (account !== this.selectedAccount || folder !== (this.selectedFolder ?? INBOX_FOLDER)) return;
    this.loadingOlder = false;
    if (!result.ok) return;

    const data = result.data as { messages?: MailMessageSummary[] };
    const page = data.messages ?? [];
    const known = new Set(this.messages.map((message) => message.msgId));
    this.messages = [...this.messages, ...page.filter((message) => !known.has(message.msgId))];
    this.#trackPagination(page.length >= MAIL_PAGE_SIZE);
  }

  /**
   * Re-derives the `before` cursor from the loaded list — its oldest dated
   * row, whichever page that came from — and records whether the page behind
   * it is worth asking for. A list with no dated row at all can't be paged
   * past, so it reads as the end of the folder regardless of `oldestPageFull`.
   */
  #trackPagination(oldestPageFull: boolean): void {
    this.#oldestCursor = oldestDate(this.messages);
    this.lastPageFull = oldestPageFull && this.#oldestCursor !== null;
  }

  /**
   * Drops the pagination state — every account/folder switch starts at page
   * one. Clearing `loadingOlder` alongside it re-enables the row for the
   * folder now on screen; the call still in flight for the previous one
   * discards its own response (see `loadOlder`).
   */
  #resetPagination(): void {
    this.#oldestCursor = null;
    this.lastPageFull = false;
    this.loadingOlder = false;
  }

  /** Loads one message's full detail (frontmatter + body) from the selected account by its indexed `msgId`. */
  async select(msgId: string): Promise<void> {
    const account = this.selectedAccount;
    if (!account) return;

    this.loading = true;
    const result = await this.#api.getMailMessage(account, msgId);
    this.loading = false;
    if (!result.ok) return;

    const data = result.data as { message?: Record<string, any> };
    const message = data.message ?? {};
    this.selected = {
      frontmatter: (message.frontmatter as Record<string, unknown> | undefined) ?? null,
      body: message.body as string,
      path: message.path as string,
      // String snake keys — the `message` map is an unconstrained
      // passthrough (see `Valea.Api.Mail`'s falsy-map-field note).
      html: typeof message.html === 'string' && message.html !== '' ? message.html : null,
      externalContent: message.external_content === true,
      senderTrusted: message.sender_trusted === true
    };
  }

  /** Kicks off a sync pass for `account`. Resolves the error code on failure, `null` on success. */
  async syncNow(account: string, generation: number): Promise<string | null> {
    const result = await this.#api.mailSyncNow(account, generation);
    return result.ok ? null : result.error;
  }

  /**
   * Executes declared ops (the archive/flag actions) against `account`
   * through the serialized executor, then refetches the affected lists.
   * Resolves the per-op results array, or a single synthesized rejection
   * when the RPC itself failed (so callers always render per-op outcomes).
   */
  async applyOps(
    account: string,
    ops: Record<string, unknown>[],
    generation: number
  ): Promise<{ op: number; result: string; reason: string | null }[]> {
    const result = await this.#api.applyMailOps(account, ops, generation);
    if (!result.ok) {
      return ops.map((_op, index) => ({ op: index, result: 'rejected', reason: result.error }));
    }

    void this.refreshFolders();
    void this.refreshMessages();
    const data = result.data as { results?: { op: number; result: string; reason: string | null }[] };
    return data.results ?? [];
  }

  /** Refetches every account's drafts with their ledger-derived states. */
  async refreshDrafts(): Promise<void> {
    const result = await this.#api.listMailDrafts();
    if (!result.ok) return;

    const data = result.data as { drafts?: unknown };
    const raw = Array.isArray(data.drafts) ? (data.drafts as Record<string, unknown>[]) : [];
    this.drafts = raw.map(normalizeMailDraft);
  }

  /**
   * Push-to-Drafts — one of the two outbound actions, both user-only
   * (`sendDraft` is the other; spec G §Invariant rewrite: Valea transmits
   * mail only on an explicit human action, hash-bound to the exact draft the
   * human reviewed, and agents have no path to either). Fetches the draft's
   * exact bytes, hashes them (sha256 hex, the backend's
   * `DraftFile.content_hash/1` encoding), and pushes bound to that revision.
   * Resolves the resulting display state, or `{error}` when any step failed;
   * always refetches the drafts list so badges reflect the ledger.
   */
  async pushDraft(
    account: string,
    draftName: string,
    generation: number
  ): Promise<{ state: string } | { error: string }> {
    const fetched = await this.#api.getMailDraft(account, draftName);
    if (!fetched.ok) return { error: fetched.error };

    const content = (fetched.data as { content: string }).content;
    const hash = await sha256Hex(content);
    const pushed = await this.#api.pushDraftToMailbox(account, draftName, hash, generation);
    void this.refreshDrafts();
    if (!pushed.ok) return { error: pushed.error };

    const data = pushed.data as { state?: string };
    return { state: data.state ?? 'pushing' };
  }

  /**
   * The atomic review snapshot behind the send confirm modal (spec G §UI).
   * Read-only — it claims nothing, transmits nothing, and deliberately does
   * NOT touch the drafts list. Resolves the normalized review, or `{error}`
   * with the raw code (map it with `sendErrorMessage`).
   */
  async draftReview(account: string, draftName: string): Promise<MailDraftReview | { error: string }> {
    const result = await this.#api.getMailDraftReview(account, draftName);
    if (!result.ok) return { error: result.error };
    return normalizeMailDraftReview(result.data as Record<string, unknown>);
  }

  /**
   * Transmits a reviewed draft — the ONE sending action in the app, and the
   * only one that cannot be undone.
   *
   * `contentHash` and `reviewFingerprint` MUST come verbatim from the
   * `draftReview` response the human just confirmed: this method never
   * re-reads the draft and never re-hashes anything (contrast `pushDraft`,
   * which owns its own fetch-and-hash). That is the one-buffer contract —
   * a hash computed from a second read could cover bytes nobody reviewed,
   * and the fingerprint is the only token binding the sending identity and
   * the resolved threading, neither of which lives in the draft bytes.
   *
   * Always refetches the drafts list, so a `sending`/`send_review`/`sent`
   * badge lands even when this call reports an error.
   */
  async sendDraft(
    account: string,
    draftName: string,
    contentHash: string,
    reviewFingerprint: string | null,
    generation: number
  ): Promise<{ state: string } | { error: string }> {
    const sent = await this.#api.sendDraft(account, draftName, contentHash, reviewFingerprint, generation);
    void this.refreshDrafts();
    if (!sent.ok) return { error: sent.error };

    const data = sent.data as { state?: string };
    return { state: data.state ?? 'sending' };
  }

  /**
   * The human's verdict on a send parked in `send_review` (spec G §Send
   * pipeline 4): `"sent"` runs the idempotent Sent copy and completes the op,
   * `"not_sent"` rejects it and reverts the draft for another explicit
   * click. Neither transmits. Resolves the error code, or `null` on success.
   */
  async resolveSendReview(
    account: string,
    opId: string,
    resolution: 'sent' | 'not_sent',
    generation: number
  ): Promise<string | null> {
    const result = await this.#api.resolveSendReview(account, opId, resolution, generation);
    void this.refreshDrafts();
    return result.ok ? null : result.error;
  }

  /** Re-runs only the idempotent Sent-copy append of a send that completed with a `sent_copy_failed` notice — never the transmit. */
  async retrySentCopy(account: string, opId: string, generation: number): Promise<string | null> {
    const result = await this.#api.retrySentCopy(account, opId, generation);
    void this.refreshDrafts();
    return result.ok ? null : result.error;
  }

  /**
   * `mail_status` push handler. Upserts the pushed account's status row by
   * slug, then — only when the push is about the SELECTED account —
   * refetches folders + messages: workspace-open activation runs
   * `Index.rebuild` asynchronously (`Valea.Mail.Engine.activate/1`), so a
   * list call issued right after open can race a still-empty index;
   * `mail_status` broadcasts once activation completes, so refetching here
   * closes that race. Every other reason the push fires (credential set,
   * settings reload, sync finish) makes the refetch a harmless no-op
   * re-read.
   */
  handleMailStatus(payload: MailStatusPush): void {
    const status = normalizeMailAccountStatus(payload);
    const index = this.accounts.findIndex((a) => a.account === status.account);
    if (index >= 0) {
      this.accounts[index] = status;
    } else {
      this.accounts = [...this.accounts, status].sort((a, b) => a.account.localeCompare(b.account));
    }
    void this.#ensureSelection();

    if (status.account === this.selectedAccount) {
      void this.refreshFolders();
      void this.refreshMessages();
    }

    void resupplyCredentials([status], this.#api);
    this.#mailStatusListeners.forEach((listener) => listener(payload));
  }

  /** `mail_sync` push handler — refresh the selected account's lists once its pass finishes. */
  handleMailSync(payload: MailSyncPush): void {
    if (payload.phase !== 'finished' || payload.account !== this.selectedAccount) return;
    void this.refreshFolders();
    void this.refreshMessages();
  }

  /** `mail_message` push handler — a message file changed on disk; only the selected account's list is showing. */
  handleMailMessage(payload: MailMessagePush): void {
    if (payload.account !== this.selectedAccount) return;
    void this.refreshMessages();
  }

  /**
   * `mail_draft` push handler — a draft file was written under
   * `sources/mail/<account>/drafts/` (an agent composing through the
   * ask-gate, or a hand edit). Unlike the folder/message handlers this is
   * deliberately NOT filtered to the selected account: `list_mail_drafts` is
   * workspace-wide in one call (the Drafts panel wants every account), and
   * `selectedDrafts` narrows it for display — so filtering here would only
   * leave a background account's rows stale while still costing the same
   * single refetch when the user switches to it.
   *
   * Refetches rather than patching the pushed row: a row's `statusDisplay`
   * is derived from the ops LEDGER backend-side, which the push (slug only)
   * says nothing about.
   */
  handleMailDraft(_payload: MailDraftPush): void {
    void this.refreshDrafts();
  }

  /**
   * Subscribes to `mail_status` pushes — beyond this store's own refetch
   * reaction (see `handleMailStatus` above). The Today page
   * (`routes/+page.svelte`) hooks this to refetch `cockpit_today`: the
   * payload's `mail` summaries are computed backend-side at request time,
   * and each Engine's async activation (plus every later credential/
   * settings/sync transition) announces itself with exactly this push.
   */
  onMailStatus(listener: (payload: MailStatusPush) => void): () => void {
    this.#mailStatusListeners.add(listener);
    return () => this.#mailStatusListeners.delete(listener);
  }

  /**
   * Keeps `selectedAccount` pointing at a real account: defaults to the
   * first valid configured account (the backend list is already
   * slug-sorted) and kicks off the folder/message loads for it; clears
   * everything when the selection vanished (account removed) and nothing
   * else is configured.
   */
  async #ensureSelection(): Promise<void> {
    const current = this.selectedAccount;
    if (current && this.accounts.some((a) => a.account === current)) return;

    const first = this.accounts.find((a) => a.valid && a.configured) ?? null;
    this.selectedAccount = first ? first.account : null;
    this.selectedFolder = INBOX_FOLDER;
    this.selected = null;
    this.#resetPagination();
    if (this.selectedAccount) {
      await Promise.all([this.refreshFolders(), this.refreshMessages()]);
    } else {
      this.folders = [];
      this.messages = [];
    }
  }
}

/**
 * The newest page merged over the previously loaded list (see
 * `refreshMessages`): every row of `page` verbatim, then the loaded rows
 * STRICTLY older than the page's oldest dated row — the same `date < before`
 * window the backend paginates on, so the kept tail is exactly what
 * `loadOlder` fetched behind that page.
 *
 * Rows inside the page's own window are dropped rather than kept-when-absent:
 * a message missing from the fresh page is missing because it was deleted or
 * moved out of the folder, and keeping it would pin it to the list until the
 * folder is re-entered. Undated rows are dropped for the same reason — they
 * only ever arrive on the newest page (nothing older than a cursor can be
 * undated), so the fresh page is their whole truth. `msgId` dedupe covers a
 * row that drifted across the boundary as new mail shifted the window down.
 */
function mergeNewestPage(page: MailMessageSummary[], loaded: MailMessageSummary[]): MailMessageSummary[] {
  const cursor = oldestDate(page);
  if (cursor === null) return page;

  const fresh = new Set(page.map((message) => message.msgId));
  const older = loaded.filter(
    (message) => message.date !== null && message.date < cursor && !fresh.has(message.msgId)
  );
  return [...page, ...older];
}

/**
 * The `date` of the last DATED row of a newest-first list — the `before`
 * cursor for the page behind it, or `null` when nothing in it carries one.
 */
function oldestDate(messages: MailMessageSummary[]): string | null {
  for (let index = messages.length - 1; index >= 0; index -= 1) {
    const date = messages[index].date;
    if (date) return date;
  }
  return null;
}

export const mailStore = new MailStore(api);

let mailEventsWired = false;

/**
 * Attaches the four mail push handlers (`mail_status`/`mail_sync`/
 * `mail_message`/`mail_draft`) to an already-joined `workspace:events`
 * channel, driving the singleton `mailStore`. Takes the channel as a
 * parameter rather than joining its own — same reason `wireIcmEvents` does
 * (see its own doc comment in `icm.svelte.ts`): Phoenix's JS client only
 * reliably delivers pushes to ONE join per topic per socket, so every store
 * rides the single `workspace:events` join `wireIcmEvents`
 * (`routes/+layout.svelte`'s one call site) owns, rather than opening a
 * second one here.
 *
 * SINGLE CALL SITE: wired from `wireIcmEvents` itself (`icm.svelte.ts`),
 * alongside `wireMountsEvents`/`wireRecentSessionsEvents` — NOT from the
 * `/mail` route directly. This keeps mail pushes flowing (and `mailStore`
 * fresh) even when the user isn't currently on `/mail`.
 *
 * Idempotent against repeat calls — a second call is a no-op rather than
 * attaching a second set of handlers (which would double-refetch on every
 * push).
 */
export function wireMailEvents(channel: Channel): void {
  if (mailEventsWired) return;
  mailEventsWired = true;

  channel.on('mail_status', (payload: MailStatusPush) => mailStore.handleMailStatus(payload));
  channel.on('mail_sync', (payload: MailSyncPush) => mailStore.handleMailSync(payload));
  channel.on('mail_message', (payload: MailMessagePush) => mailStore.handleMailMessage(payload));
  channel.on('mail_draft', (payload: MailDraftPush) => mailStore.handleMailDraft(payload));
}

/**
 * Silent credential recovery (mail design spec §Credentials, "Recovery"): a
 * backend restart drops every Engine's in-memory credential, so accounts
 * come back `configured: true, credential: 'missing'` even though nothing
 * about them changed. In the desktop app each secret is still sitting in
 * the OS keychain from the original account-setup hand-off, so there's no
 * need to make the user re-type passwords — this reads each one back and
 * re-supplies it over the RPC, exactly like the initial hand-off does.
 *
 * The keychain entry is keyed `workspace_id` / `<slug>:imap` — the account
 * SLUG, not the IMAP login: slugs are unique per workspace by construction
 * (`config/mail.yaml`'s account map), whereas two accounts could share a
 * username across hosts. Matches `submitMailSetup`'s write key
 * (`mail-shapes.ts`).
 *
 * SMTP (spec G) is a SEPARATE entry (`<slug>:smtp`) resupplied on the same
 * pass and handed over with `kind: 'smtp'` — a copy of the IMAP secret at
 * setup time, never an alias, so the two rotate independently. The two slots
 * are also independent HERE: an account whose IMAP credential survived can
 * still be missing its SMTP one, and a push-only account (`smtpCredential:
 * 'n/a'`) is never asked for one at all.
 *
 * Per-slot and self-terminating: only valid, configured accounts with a
 * `missing` slot and a known `workspaceId` are attempted, a missing keychain
 * entry just skips that slot, and a successful resupply flips that Engine's
 * credential to `"present"`, so the next `mail_status` push it causes fails
 * the filter instead of looping. Resolves the number of SECRETS actually
 * resupplied — up to two per account (browser: always 0 — no keychain).
 */
export async function resupplyCredentials(
  accounts: MailAccountStatus[],
  apiOverride: Pick<Api, 'setMailCredential'> = api
): Promise<number> {
  if (!inDesktop()) return 0;

  let resupplied = 0;
  for (const status of accounts) {
    if (!status.valid || !status.configured || !status.workspaceId) continue;

    if (status.credential === 'missing') {
      if (await resupplySlot(status.workspaceId, status.account, 'imap', apiOverride)) resupplied += 1;
    }

    if (status.smtpConfigured && status.smtpCredential === 'missing') {
      if (await resupplySlot(status.workspaceId, status.account, 'smtp', apiOverride)) resupplied += 1;
    }
  }
  return resupplied;
}

/** One `<slug>:<kind>` keychain read + hand-off; `false` when nothing was stored or the RPC refused it. */
async function resupplySlot(
  workspaceId: string,
  account: string,
  kind: 'imap' | 'smtp',
  apiOverride: Pick<Api, 'setMailCredential'>
): Promise<boolean> {
  const secret = await keychainGet(workspaceId, `${account}:${kind}`);
  if (secret === null) return false;

  const generation = workspaceStore.generation ?? 0;
  // The IMAP call stays 3-arity — the `kind` argument is omitted, not passed
  // as `'imap'`, so this path is byte-for-byte the pre-spec-G call.
  const result =
    kind === 'imap'
      ? await apiOverride.setMailCredential(account, secret, generation)
      : await apiOverride.setMailCredential(account, secret, generation, 'smtp');
  return result.ok;
}
