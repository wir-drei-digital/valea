import { api, type Api } from '../api/client';
import { workspaceStore } from './workspace.svelte';
import { inDesktop, keychainGet } from '../keychain';
import type { MailStatusPush, MailSyncPush, MailMessagePush } from '../socket';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as the other T16+ stores, so tests can inject a fake without
 * implementing every wrapped call. `setMailCredential` is included even
 * though no `MailStore` method calls it directly — `handleMailStatus`
 * forwards this same injected api into the module-level `resupplyCredential`
 * helper below (see its doc comment) rather than reaching for the `api`
 * singleton, so a store built with a fake api never has a side effect leak
 * out through the real one.
 */
type MailApi = Pick<
  Api,
  'mailStatus' | 'listMailMessages' | 'mailInbox' | 'getMailMessage' | 'mailSyncNow' | 'setMailCredential'
>;

/** App-facing mail status — camelCased/typed from the raw `MailStatusPush` wire shape. */
export type MailStatus = {
  configured: boolean;
  credential: 'present' | 'missing';
  state: string;
  lastSyncAt: string | null;
  lastError: string | null;
  account: string | null;
  /**
   * Persistent workspace UUID (`config/workspace.yaml`, mail design spec
   * §Seed & migration). Not part of anything shown directly in the mail UI,
   * but carried on this type (rather than tracked as separate internal
   * store state) since it's just another field of the same status payload —
   * `resupplyCredential` below needs it for the keychain's
   * `workspace_id:username` lookup key (spec §Credentials).
   */
  workspaceId: string | null;
};

/** One row of `list_mail_messages` — mirrors `listMailMessagesFields` in `api/client.ts`. */
export type MailMessageSummary = {
  msgId: string;
  fromName: string | null;
  fromEmail: string | null;
  subject: string | null;
  date: string | null;
  status: string | null;
  hasAttachments: boolean;
  uid: number | null;
  path: string | null;
};

/** One row of `mail_inbox` — mirrors `mailInboxFields` in `api/client.ts`. */
export type InboxEntry = {
  uid: number;
  fromText: string | null;
  subject: string | null;
  date: string | null;
};

/** `get_mail_message`'s result — the parsed message file plus whether it's inbox-only. */
export type MailMessageDetail = {
  frontmatter: Record<string, unknown> | null;
  body: string;
  path: string;
  inbox: boolean;
};

/**
 * Normalizes a raw `mail_status` wire payload (RPC `status` field or the
 * `mail_status` channel push — both carry the identical snake_case shape,
 * see `MailStatusPush`'s doc comment in `socket.ts`) into the camelCase
 * `MailStatus` app shape. `credential` is defensively narrowed to the
 * closed union rather than trusted as-is, mirroring `normalizeIcmNode`'s
 * `type === 'folder' ? 'folder' : 'page'` guard in `icm.svelte.ts`.
 */
export function normalizeMailStatus(raw: MailStatusPush): MailStatus {
  return {
    configured: raw.configured,
    credential: raw.credential === 'present' ? 'present' : 'missing',
    state: raw.state,
    lastSyncAt: raw.last_sync_at,
    lastError: raw.last_error,
    account: raw.account,
    workspaceId: raw.workspace_id
  };
}

/**
 * Live view of the mail account: status, the indexed message list, the raw
 * IMAP inbox header cache, and the currently open message's detail.
 *
 * `handleMailStatus`/`handleMailSync`/`handleMailMessage` are plain public
 * methods, not wired to a channel by this store itself — per this
 * codebase's established `workspace:events` convention (see `wireIcmEvents`
 * in `icm.svelte.ts`), only ONE `joinWorkspaceEvents` call site may exist
 * (a second independent join to the same topic races it and only one
 * reliably receives pushes). Wiring these three into that single join is a
 * later route/layout task's job — it should pass closures like
 * `onMailStatus: (payload) => mailStore.handleMailStatus(payload)` (methods
 * are NOT pre-bound here, matching this codebase's plain-method style
 * elsewhere).
 */
export class MailStore {
  status: MailStatus | null = $state(null);
  messages: MailMessageSummary[] = $state([]);
  inbox: InboxEntry[] = $state([]);
  selected: MailMessageDetail | null = $state(null);
  /**
   * In-flight flag for `select()` (the one async call heavy/slow enough —
   * it reads a whole message file — to warrant a UI spinner). `refreshStatus`/
   * `refreshMessages`/`refreshInbox` don't get their own flags: unlike the
   * single-collection stores elsewhere (`icmStore.loaded`, `queueStore.loaded`,
   * ...), this store's brief only calls for the one `loading` field, and an
   * empty `messages`/`inbox` array before the first successful refetch is
   * an adequate "not loaded yet" signal for those three.
   */
  loading = $state(false);

  #api: MailApi;

  constructor(api: MailApi) {
    this.#api = api;
  }

  async refreshStatus(): Promise<void> {
    const result = await this.#api.mailStatus();
    if (!result.ok) return;

    const data = result.data as { status?: MailStatusPush };
    if (!data.status) return;
    this.#applyStatus(data.status);
  }

  async refreshMessages(): Promise<void> {
    const result = await this.#api.listMailMessages();
    if (!result.ok) return;

    const data = result.data as { messages?: MailMessageSummary[] };
    this.messages = data.messages ?? [];
  }

  async refreshInbox(): Promise<void> {
    const result = await this.#api.mailInbox();
    if (!result.ok) return;

    const data = result.data as { entries?: InboxEntry[] };
    this.inbox = data.entries ?? [];
  }

  /** Loads one message's full detail (frontmatter + body) by its indexed `msgId`. */
  async select(msgId: string): Promise<void> {
    this.loading = true;
    const result = await this.#api.getMailMessage(msgId);
    this.loading = false;
    if (!result.ok) return;

    const data = result.data as { message?: Record<string, any>; inbox: boolean };
    const message = data.message ?? {};
    this.selected = {
      frontmatter: (message.frontmatter as Record<string, unknown> | undefined) ?? null,
      body: message.body as string,
      path: message.path as string,
      inbox: data.inbox
    };
  }

  /** Kicks off a sync pass. Resolves the error code on failure, `null` on success. */
  async syncNow(generation: number): Promise<string | null> {
    const result = await this.#api.mailSyncNow(generation);
    return result.ok ? null : result.error;
  }

  /**
   * `mail_status` push handler. Refetches `messages`/`inbox` unconditionally
   * on every call — deliberately not trying to detect "this is specifically
   * the activation-triggered push" (the payload carries no such marker):
   * workspace-open activation runs `Index.rebuild` asynchronously
   * (`Valea.Mail.Engine.activate/1`), so a `list_mail_messages`/`mail_inbox`
   * call issued right after open can race a still-empty index (T13 report,
   * "Concerns for T14"). `mail_status` broadcasts once activation
   * completes, so refetching here closes that race. Every other reason a
   * `mail_status` push fires (credential set, settings reload, sync
   * finish) makes the refetch a harmless no-op re-read — same "just
   * refetch on any related push" simplicity `icmStore`/`queueStore`/
   * `auditStore` already use for their own change pushes.
   */
  handleMailStatus(payload: MailStatusPush): void {
    this.#applyStatus(payload);
    void this.refreshMessages();
    void this.refreshInbox();
  }

  /**
   * `mail_sync` push handler. `newMessages`/`started` at the top of a pass
   * carries nothing to react to yet (this store has no dedicated
   * "syncing" phase field); per-message `mail_message` pushes already keep
   * `messages` current as the pass runs (see `handleMailMessage`). Once
   * the pass finishes, `inbox` (the separate IMAP-header cache,
   * `Store.inbox_headers()`) isn't announced per-message, so refresh it
   * once here.
   */
  handleMailSync(payload: MailSyncPush): void {
    if (payload.phase !== 'finished') return;
    void this.refreshInbox();
  }

  /** `mail_message` push handler — a message file was created/updated on disk. */
  handleMailMessage(_payload: MailMessagePush): void {
    void this.refreshMessages();
  }

  #applyStatus(raw: MailStatusPush): void {
    this.status = normalizeMailStatus(raw);
    void resupplyCredential(this.status, this.#api);
  }
}

export const mailStore = new MailStore(api);

/**
 * Silent credential recovery (mail design spec §Credentials, "Recovery"): a
 * backend restart drops the Engine's in-memory credential, so `mail_status`
 * comes back `configured: true, credential: 'missing'` even though nothing
 * about the account itself changed. In the desktop app the secret is still
 * sitting in the OS keychain from the original account-setup hand-off, so
 * there's no need to make the user re-type a password — this reads it back
 * and re-supplies it over the RPC, exactly like the initial hand-off does.
 *
 * No-ops (resolves `false`) outside the desktop app, when the account isn't
 * configured, when the credential is already present, when the status
 * carries no `workspaceId`/`account` to look a secret up under, or when the
 * keychain has nothing stored for that key — every one of these is a
 * legitimate "can't/don't need to resupply" state, not an error worth
 * surfacing. Self-terminating: a successful resupply flips the Engine's
 * credential to `"present"`, so the next `mail_status` push this causes
 * fails the `credential !== 'missing'` guard instead of looping.
 *
 * `username` for the keychain lookup is `status.account` — `mail_status`
 * doesn't expose the IMAP `username` argument separately from the
 * account/display email `setup_mail_account` was called with
 * (`Valea.Mail.Engine.build_status/1` only surfaces `settings.account`),
 * and the setup flow keychain-stores the credential under that same value,
 * so this is the correct lookup key, not an approximation.
 *
 * `apiOverride` defaults to the real `api` singleton but is always passed
 * explicitly by `MailStore` (its own injected `#api`) — same
 * dependency-injection-with-a-default-for-tests shape as
 * `AgentSessionStore`'s `join` constructor parameter.
 */
export async function resupplyCredential(
  status: MailStatus,
  apiOverride: Pick<Api, 'setMailCredential'> = api
): Promise<boolean> {
  if (!inDesktop()) return false;
  if (!status.configured || status.credential !== 'missing') return false;
  if (!status.workspaceId || !status.account) return false;

  const secret = await keychainGet(status.workspaceId, status.account);
  if (secret === null) return false;

  const generation = workspaceStore.generation ?? 0;
  const result = await apiOverride.setMailCredential(secret, generation);
  return result.ok;
}
