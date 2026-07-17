import { api, type Api } from '../api/client';
import { workspaceStore } from './workspace.svelte';
import { inDesktop, keychainGet } from '../keychain';
import type { MailStatusPush, MailSyncPush, MailMessagePush } from '../socket';
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
  'mailStatus' | 'listMailFolders' | 'listMailMessages' | 'getMailMessage' | 'mailSyncNow' | 'setMailCredential'
>;

const INBOX_FOLDER = 'INBOX';

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

/** `get_mail_message`'s result — the parsed message view file. */
export type MailMessageDetail = {
  frontmatter: Record<string, unknown> | null;
  body: string;
  path: string;
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
    notices: strings(raw.notices)
  };
}

/**
 * Live view of the configured mail accounts: the per-account status list,
 * the selected account's folder list, the selected folder's message list,
 * and the currently open message's detail.
 *
 * `handleMailStatus`/`handleMailSync`/`handleMailMessage` are plain public
 * methods, not wired to a channel by this store itself — per this
 * codebase's established `workspace:events` convention (see `wireIcmEvents`
 * in `icm.svelte.ts`), only ONE `joinWorkspaceEvents` call site may exist.
 * All three payloads carry the account slug; the folder/message refetches
 * are FILTERED to the currently selected account (a push for a background
 * account only upserts its status row), so a busy second account can't
 * churn the list the user is actually reading.
 */
export class MailStore {
  accounts: MailAccountStatus[] = $state([]);
  selectedAccount: string | null = $state(null);
  folders: MailFolder[] = $state([]);
  selectedFolder: string | null = $state(INBOX_FOLDER);
  messages: MailMessageSummary[] = $state([]);
  selected: MailMessageDetail | null = $state(null);
  /**
   * In-flight flag for `select()` (the one async call heavy/slow enough —
   * it reads a whole message file — to warrant a UI spinner). The list
   * refreshes don't get their own flags: an empty `folders`/`messages`
   * array before the first successful refetch is an adequate "not loaded
   * yet" signal.
   */
  loading = $state(false);

  #api: MailApi;

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
   * Switches the UI to `slug`: resets the folder selection to INBOX, drops
   * the open message detail, and refetches folders + messages. A re-select
   * of the current account is a no-op.
   */
  async selectAccount(slug: string): Promise<void> {
    if (slug === this.selectedAccount) return;
    this.selectedAccount = slug;
    this.selectedFolder = INBOX_FOLDER;
    this.selected = null;
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

  /** Switches the message list to `name` within the selected account. */
  async selectFolder(name: string): Promise<void> {
    this.selectedFolder = name;
    await this.refreshMessages();
  }

  /** Lists the selected folder of the selected account — a no-op that clears `messages` when no account is known yet. */
  async refreshMessages(): Promise<void> {
    const account = this.selectedAccount;
    if (!account) {
      this.messages = [];
      return;
    }

    const result = await this.#api.listMailMessages(account, this.selectedFolder ?? INBOX_FOLDER);
    if (!result.ok) return;

    const data = result.data as { messages?: MailMessageSummary[] };
    this.messages = data.messages ?? [];
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
      path: message.path as string
    };
  }

  /** Kicks off a sync pass for `account`. Resolves the error code on failure, `null` on success. */
  async syncNow(account: string, generation: number): Promise<string | null> {
    const result = await this.#api.mailSyncNow(account, generation);
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
    if (this.selectedAccount) {
      await Promise.all([this.refreshFolders(), this.refreshMessages()]);
    } else {
      this.folders = [];
      this.messages = [];
    }
  }
}

export const mailStore = new MailStore(api);

let mailEventsWired = false;

/**
 * Attaches the three mail push handlers (`mail_status`/`mail_sync`/
 * `mail_message`) to an already-joined `workspace:events` channel, driving
 * the singleton `mailStore`. Takes the channel as a parameter rather than
 * joining its own — same reason `wireIcmEvents` does (see its own doc
 * comment in `icm.svelte.ts`): Phoenix's JS client only reliably delivers
 * pushes to ONE join per topic per socket, so every store rides the single
 * `workspace:events` join `wireIcmEvents` (`routes/+layout.svelte`'s one
 * call site) owns, rather than opening a second one here.
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
 * Per-account and self-terminating: only valid, configured accounts with
 * `credential === 'missing'` and a known `workspaceId` are attempted, a
 * missing keychain entry just skips that account, and a successful resupply
 * flips that Engine's credential to `"present"`, so the next `mail_status`
 * push it causes fails the filter instead of looping. Resolves the number
 * of accounts actually resupplied (browser: always 0 — no keychain).
 */
export async function resupplyCredentials(
  accounts: MailAccountStatus[],
  apiOverride: Pick<Api, 'setMailCredential'> = api
): Promise<number> {
  if (!inDesktop()) return 0;

  let resupplied = 0;
  for (const status of accounts) {
    if (!status.valid || !status.configured || status.credential !== 'missing') continue;
    if (!status.workspaceId) continue;

    const secret = await keychainGet(status.workspaceId, `${status.account}:imap`);
    if (secret === null) continue;

    const generation = workspaceStore.generation ?? 0;
    const result = await apiOverride.setMailCredential(status.account, secret, generation);
    if (result.ok) resupplied += 1;
  }
  return resupplied;
}
