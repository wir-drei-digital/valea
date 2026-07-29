import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  MailStore,
  mailStore,
  MAIL_PAGE_SIZE,
  normalizeMailAccountStatus,
  normalizeMailDraft,
  normalizeMailDraftReview,
  resupplyCredentials,
  wireMailEvents,
  type MailAccountStatus
} from './mail.svelte';
import { sha256Hex } from '../components/mail/mail-shapes';
import { inDesktop, keychainGet } from '../keychain';
import type { ApiResult } from '../api/client';
import type { MailStatusPush } from '../socket';
import type { Channel } from 'phoenix';

// The keychain seam is mocked at the module boundary (mirrors
// keychain.test.ts mocking `@tauri-apps/api/core`) so `resupplyCredentials`'
// desktop path — including WHICH key each secret is looked up under — is
// drivable from vitest, where no real Tauri bridge exists. Defaults mimic
// the browser environment (not desktop, nothing stored); desktop-path tests
// override per-test.
vi.mock('../keychain', () => ({
  inDesktop: vi.fn(() => false),
  keychainGet: vi.fn(async () => null)
}));

beforeEach(() => {
  vi.mocked(inDesktop).mockReset().mockReturnValue(false);
  vi.mocked(keychainGet).mockReset().mockResolvedValue(null);
});

type StatusResult = ApiResult<{ accounts: Record<string, any>[] }>;
type FoldersResult = ApiResult<{ folders: any[] }>;
type MessagesResult = ApiResult<{ messages: any[] }>;
type DetailResult = ApiResult<{ message: Record<string, any> }>;
type SyncResult = ApiResult<{ started: boolean }>;
type CredentialResult = ApiResult<{ accepted: boolean }>;
type OpsResult = ApiResult<{ results: { op: number; result: string; reason: string | null }[] }>;
type DraftsResult = ApiResult<{ drafts: Record<string, any>[] }>;
type DraftContentResult = ApiResult<{ content: string; path: string }>;
type WriteDraftResult = ApiResult<{ name: string; saved: boolean }>;
type AccountSettingsResult = ApiResult<{
  account: { host: string; port: number; username: string; smtp: Record<string, any> | null };
}>;
type PushResult = ApiResult<{ state: string }>;
type ReviewResult = ApiResult<Record<string, any>>;
type SendResult = ApiResult<{ state: string }>;
type ResolveResult = ApiResult<{ resolved: boolean }>;
type RetryResult = ApiResult<{ retried: boolean }>;

// `account` (the slug) deliberately differs from `username` (the IMAP
// login) throughout these fixtures — the keychain lookup keys on the SLUG
// (`<slug>:imap`), and a fixture where the two coincide couldn't catch a
// mixup between them. Two accounts throughout: the multi-account paths
// (switching, push filtering, resupply) are this store's whole point.
const rawMara: Record<string, any> = {
  account: 'mara',
  valid: true,
  configured: true,
  credential: 'present',
  state: 'idle',
  last_sync_at: '2026-07-10T12:00:00Z',
  last_error: null,
  username: 'mara@example.com',
  workspace_id: 'ws-1',
  pending_ops: 2,
  held_folders: ['Old/Archive'],
  notices: ['one notice']
};

const rawZoe: Record<string, any> = {
  account: 'zoe',
  valid: true,
  configured: true,
  credential: 'present',
  state: 'idle',
  last_sync_at: null,
  last_error: null,
  username: 'zoe@example.com',
  workspace_id: 'ws-1',
  pending_ops: 0,
  held_folders: [],
  notices: []
};

function fakeApi(overrides: {
  mailStatus?: () => Promise<StatusResult>;
  listMailFolders?: (account: string) => Promise<FoldersResult>;
  listMailMessages?: (account: string, folder: string, opts?: object) => Promise<MessagesResult>;
  searchMail?: (account: string, query: string, opts?: object) => Promise<MessagesResult>;
  getMailMessage?: (account: string, msgId: string) => Promise<DetailResult>;
  mailSyncNow?: (account: string, generation: number) => Promise<SyncResult>;
  setMailCredential?: (
    account: string,
    secret: string,
    generation: number,
    kind?: 'imap' | 'smtp'
  ) => Promise<CredentialResult>;
  applyMailOps?: (account: string, ops: Record<string, unknown>[], generation: number) => Promise<OpsResult>;
  listMailDrafts?: () => Promise<DraftsResult>;
  getMailDraft?: (account: string, draftName: string) => Promise<DraftContentResult>;
  writeMailDraft?: (
    account: string,
    name: string | null,
    content: string,
    baseHash: string | null,
    generation: number
  ) => Promise<WriteDraftResult>;
  getMailAccountSettings?: (account: string) => Promise<AccountSettingsResult>;
  pushDraftToMailbox?: (
    account: string,
    draftName: string,
    contentHash: string,
    generation: number
  ) => Promise<PushResult>;
  getMailDraftReview?: (account: string, draftName: string) => Promise<ReviewResult>;
  sendDraft?: (
    account: string,
    draftName: string,
    contentHash: string,
    reviewFingerprint: string | null,
    generation: number
  ) => Promise<SendResult>;
  resolveSendReview?: (
    account: string,
    opId: string,
    resolution: 'sent' | 'not_sent',
    generation: number
  ) => Promise<ResolveResult>;
  retrySentCopy?: (account: string, opId: string, generation: number) => Promise<RetryResult>;
}) {
  return {
    mailStatus:
      overrides.mailStatus ?? (async () => ({ ok: true, data: { accounts: [rawMara, rawZoe] } }) as StatusResult),
    listMailFolders:
      overrides.listMailFolders ?? (async () => ({ ok: true, data: { folders: [] } }) as FoldersResult),
    listMailMessages:
      overrides.listMailMessages ?? (async () => ({ ok: true, data: { messages: [] } }) as MessagesResult),
    searchMail: overrides.searchMail ?? (async () => ({ ok: true, data: { messages: [] } }) as MessagesResult),
    getMailMessage:
      overrides.getMailMessage ?? (async () => ({ ok: true, data: { message: {} } }) as DetailResult),
    mailSyncNow: overrides.mailSyncNow ?? (async () => ({ ok: true, data: { started: true } }) as SyncResult),
    setMailCredential:
      overrides.setMailCredential ?? (async () => ({ ok: true, data: { accepted: true } }) as CredentialResult),
    applyMailOps: overrides.applyMailOps ?? (async () => ({ ok: true, data: { results: [] } }) as OpsResult),
    listMailDrafts:
      overrides.listMailDrafts ?? (async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult),
    getMailDraft:
      overrides.getMailDraft ??
      (async () => ({ ok: true, data: { content: '', path: '' } }) as DraftContentResult),
    writeMailDraft:
      overrides.writeMailDraft ??
      (async (_account: string, name: string | null) =>
        ({ ok: true, data: { name: name ?? 'minted', saved: true } }) as WriteDraftResult),
    getMailAccountSettings:
      overrides.getMailAccountSettings ??
      (async () =>
        ({
          ok: true,
          data: { account: { host: 'imap.example.com', port: 993, username: 'login', smtp: null } }
        }) as AccountSettingsResult),
    pushDraftToMailbox:
      overrides.pushDraftToMailbox ?? (async () => ({ ok: true, data: { state: 'pushing' } }) as PushResult),
    getMailDraftReview:
      overrides.getMailDraftReview ?? (async () => ({ ok: true, data: rawReview }) as ReviewResult),
    sendDraft: overrides.sendDraft ?? (async () => ({ ok: true, data: { state: 'sent' } }) as SendResult),
    resolveSendReview:
      overrides.resolveSendReview ?? (async () => ({ ok: true, data: { resolved: true } }) as ResolveResult),
    retrySentCopy:
      overrides.retrySentCopy ?? (async () => ({ ok: true, data: { retried: true } }) as RetryResult)
  };
}

// `get_mail_draft_review`'s payload exactly as it arrives: the action's
// TYPED top-level fields camelCased by codegen (`contentHash`,
// `threadingWarning`, `reviewFingerprint`, `smtpConfigured`), the
// unconstrained nested maps (`recipients`/`threading`/`identity`) verbatim
// as `OpsExecutor.review_snapshot/2` builds them — snake keys inside.
const rawReview: Record<string, any> = {
  content: '---\nto: [alex@example.com]\nsubject: "Re: Kickoff"\n---\nBody.\n',
  contentHash: 'a'.repeat(64),
  recipients: {
    to: [{ name: null, email: 'alex@example.com' }],
    cc: [{ name: 'Bo', email: 'bo@example.com' }],
    bcc: []
  },
  subject: 'Re: Kickoff',
  attachments: [{ filename: 'deck.pdf', path: 'notes/deck.pdf', bytes: 2048 }],
  threading: { in_reply_to: '<m1@example.com>', references: ['<m0@example.com>'] },
  threadingWarning: false,
  identity: { from: 'mara@example.com', from_name: 'Mara Vance', account: 'mara' },
  reviewFingerprint: 'fp-' + 'b'.repeat(61),
  smtpConfigured: true
};

/** Drains the microtask queue so the store's fire-and-forget (`void`) refetches settle before asserting. */
function flush(): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, 0));
}

function pushFor(raw: Record<string, any>): MailStatusPush {
  // Channel pushes are the engine status WITHOUT `valid`/`reason` (an
  // engine only exists for valid config) — strip them from the RPC fixture.
  const { valid: _valid, reason: _reason, ...rest } = raw;
  return rest as MailStatusPush;
}

describe('normalizeMailAccountStatus', () => {
  it('camelCases a full valid entry and narrows credential', () => {
    expect(normalizeMailAccountStatus(rawMara)).toEqual({
      account: 'mara',
      valid: true,
      reason: null,
      configured: true,
      credential: 'present',
      state: 'idle',
      lastSyncAt: '2026-07-10T12:00:00Z',
      lastError: null,
      username: 'mara@example.com',
      workspaceId: 'ws-1',
      pendingOps: 2,
      heldFolders: ['Old/Archive'],
      notices: ['one notice'],
      folders: null,
      smtpConfigured: false,
      smtpCredential: 'n/a'
    } satisfies MailAccountStatus);
  });

  // `smtp_configured`/`smtp_credential` ride STRING keys on the engine's
  // status map (`Valea.Mail.Engine`'s `@type status` — the falsy-map-field
  // rule), and `accounts` is delivered raw, so they arrive snake_cased like
  // every other entry field.
  it('maps the string-keyed smtp status fields', () => {
    const normalized = normalizeMailAccountStatus({
      ...rawMara,
      smtp_configured: true,
      smtp_credential: 'missing'
    });

    expect(normalized.smtpConfigured).toBe(true);
    expect(normalized.smtpCredential).toBe('missing');
  });

  it('defaults a push-only account to smtpConfigured=false / smtpCredential="n/a"', () => {
    expect(normalizeMailAccountStatus(rawMara)).toMatchObject({
      smtpConfigured: false,
      smtpCredential: 'n/a'
    });
    // An unrecognized value narrows to the closed union's "no smtp" member
    // rather than being trusted through (same posture as `credential`).
    expect(normalizeMailAccountStatus({ ...rawMara, smtp_credential: 'weird' }).smtpCredential).toBe('n/a');
  });

  it('normalizes the configured folder-name map when present', () => {
    const normalized = normalizeMailAccountStatus({
      ...rawMara,
      folders: { drafts: 'Drafts', sent: 'Sent', archive: '[Gmail]/All Mail', trash: '[Gmail]/Trash' }
    });

    expect(normalized.folders).toEqual({
      drafts: 'Drafts',
      sent: 'Sent',
      archive: '[Gmail]/All Mail',
      trash: '[Gmail]/Trash'
    });
  });

  it('degrades an invalid-config entry (only account/state/reason present) to empty defaults', () => {
    const normalized = normalizeMailAccountStatus({
      account: 'broken',
      valid: false,
      state: 'invalid_config',
      reason: 'bad slug'
    });

    expect(normalized).toMatchObject({
      account: 'broken',
      valid: false,
      reason: 'bad slug',
      configured: false,
      credential: 'missing',
      state: 'invalid_config',
      pendingOps: 0,
      heldFolders: [],
      notices: []
    });
  });

  it('defaults valid to true when the field is absent (channel pushes)', () => {
    expect(normalizeMailAccountStatus(pushFor(rawMara) as never).valid).toBe(true);
  });
});

describe('MailStore.refreshStatus', () => {
  it('populates accounts and defaults selection to the first valid configured account', async () => {
    const listMailFolders = vi.fn(async () => ({ ok: true, data: { folders: [] } }) as FoldersResult);
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailFolders, listMailMessages }) as never);

    await store.refreshStatus();

    expect(store.accounts.map((a) => a.account)).toEqual(['mara', 'zoe']);
    expect(store.selectedAccount).toBe('mara');
    expect(store.selectedFolder).toBe('INBOX');
    expect(listMailFolders).toHaveBeenCalledWith('mara');
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  it('skips invalid and unconfigured entries when defaulting the selection', async () => {
    const invalid = { account: 'aaa-broken', valid: false, state: 'invalid_config', reason: 'x' };
    const store = new MailStore(
      fakeApi({ mailStatus: async () => ({ ok: true, data: { accounts: [invalid, rawZoe] } }) }) as never
    );

    await store.refreshStatus();

    expect(store.selectedAccount).toBe('zoe');
  });

  it('clears the selection (and lists) when every account vanished', async () => {
    const store = new MailStore(fakeApi({}) as never);
    await store.refreshStatus();

    const empty = new MailStore(fakeApi({ mailStatus: async () => ({ ok: true, data: { accounts: [] } }) }) as never);
    await empty.refreshStatus();

    expect(empty.selectedAccount).toBeNull();
    expect(empty.folders).toEqual([]);
    expect(empty.messages).toEqual([]);
  });

  it('keeps an existing still-present selection instead of snapping back to the first account', async () => {
    const store = new MailStore(fakeApi({}) as never);
    await store.refreshStatus();
    await store.selectAccount('zoe');

    await store.refreshStatus();

    expect(store.selectedAccount).toBe('zoe');
  });

  it('leaves state untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ mailStatus: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshStatus();

    expect(store.accounts).toEqual([]);
    expect(store.selectedAccount).toBeNull();
  });
});

describe('MailStore.selectAccount', () => {
  it('switches account, resets the folder to INBOX, clears the open detail, and refetches both lists', async () => {
    const listMailFolders = vi.fn(async () => ({ ok: true, data: { folders: [] } }) as FoldersResult);
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailFolders, listMailMessages }) as never);
    await store.refreshStatus();
    await store.selectFolder('Archive');
    store.selected = {
      frontmatter: null,
      body: 'x',
      path: 'p',
      html: null,
      externalContent: false,
      senderTrusted: false
    };
    listMailFolders.mockClear();
    listMailMessages.mockClear();

    await store.selectAccount('zoe');

    expect(store.selectedAccount).toBe('zoe');
    expect(store.selectedFolder).toBe('INBOX');
    expect(store.selected).toBeNull();
    expect(listMailFolders).toHaveBeenCalledWith('zoe');
    expect(listMailMessages).toHaveBeenCalledWith('zoe', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  // The switch must not leave the OLD account's folders/messages on screen
  // while the new account's lists are in flight — with a slow backend that
  // window is long enough to click a message that belongs to the account the
  // user just switched away from.
  it("clears the previous account's lists synchronously, before the refetch lands", async () => {
    const folders = [{ name: 'INBOX', dir: 'INBOX', held: false, messageCount: 4, backfillComplete: true }];
    const messages = [{ msgId: 'm1', subject: 'Alpha' }];
    // Once `stalled` flips, the refetches never resolve — so whatever the
    // store still shows is unambiguously the previous account's data.
    let stalled = false;
    const listMailFolders = vi.fn(async () =>
      stalled ? new Promise<FoldersResult>(() => {}) : ({ ok: true, data: { folders } } as FoldersResult)
    );
    const listMailMessages = vi.fn(async () =>
      stalled ? new Promise<MessagesResult>(() => {}) : ({ ok: true, data: { messages } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailFolders, listMailMessages }) as never);
    await store.refreshStatus();
    expect(store.folders).toEqual(folders);
    expect(store.messages).toEqual(messages);

    stalled = true;
    void store.selectAccount('zoe');

    expect(store.folders).toEqual([]);
    expect(store.messages).toEqual([]);
  });

  it('is a no-op when re-selecting the current account', async () => {
    const listMailFolders = vi.fn(async () => ({ ok: true, data: { folders: [] } }) as FoldersResult);
    const store = new MailStore(fakeApi({ listMailFolders }) as never);
    await store.refreshStatus();
    await store.selectFolder('Archive');
    listMailFolders.mockClear();

    await store.selectAccount('mara');

    expect(store.selectedFolder).toBe('Archive');
    expect(listMailFolders).not.toHaveBeenCalled();
  });
});

describe('MailStore folders + messages', () => {
  it('refreshFolders populates the folder list for the selected account', async () => {
    const folders = [{ name: 'INBOX', dir: 'INBOX', held: false, messageCount: 4, backfillComplete: true }];
    const store = new MailStore(
      fakeApi({ listMailFolders: async () => ({ ok: true, data: { folders } }) }) as never
    );
    await store.refreshStatus();

    expect(store.folders).toEqual(folders);
  });

  it('refreshFolders clears (without a call) when no account is selected', async () => {
    const listMailFolders = vi.fn(async () => ({ ok: true, data: { folders: [] } }) as FoldersResult);
    const store = new MailStore(fakeApi({ listMailFolders }) as never);

    await store.refreshFolders();

    expect(store.folders).toEqual([]);
    expect(listMailFolders).not.toHaveBeenCalled();
  });

  it('selectFolder refetches messages from the newly selected folder', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    await store.selectFolder('Archive');

    expect(store.selectedFolder).toBe('Archive');
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'Archive', { limit: MAIL_PAGE_SIZE });
  });

  it('refreshMessages leaves messages untouched on failure', async () => {
    const messages = [{ msgId: 'm1' }];
    let fail = false;
    const store = new MailStore(
      fakeApi({
        listMailMessages: async () =>
          fail ? ({ ok: false, error: 'not_found' } as MessagesResult) : ({ ok: true, data: { messages } } as MessagesResult)
      }) as never
    );
    await store.refreshStatus();
    expect(store.messages).toEqual(messages);

    fail = true;
    await store.refreshMessages();

    expect(store.messages).toEqual(messages);
  });
});

/**
 * Descending ISO timestamps, one minute apart. `mail_messages.date` is a
 * plain STRING column the backend both sorts and cursors on lexicographically
 * (`date < ^before` in `Valea.Mail.Store.list_messages/4`), so a fixture only
 * has to keep the strings ordered — no parsing happens on either side.
 */
function isoAt(index: number): string {
  return new Date(Date.UTC(2026, 6, 29, 12, 0, 0) - index * 60_000).toISOString();
}

/** `count` index rows, newest first, starting `offset` minutes back. */
function rows(count: number, offset = 0): Record<string, any>[] {
  return Array.from({ length: count }, (_v, i) => ({ msgId: `m${offset + i}`, date: isoAt(offset + i) }));
}

/**
 * `list_mail_messages` over one folder, faithful to the action it stands in
 * for: newest-first, at most `limit` rows, everything STRICTLY older than
 * `before`. Pagination is only worth asserting against a fake that actually
 * paginates — `all` is read on every call, so a test can mutate it to stage
 * arrivals and deletions between refetches.
 */
function pagedFolder(all: Record<string, any>[]) {
  return vi.fn(async (_account: string, _folder: string, opts: { limit?: number; before?: string } = {}) => {
    const behind = opts.before ? all.filter((row) => row.date < opts.before!) : all;
    return { ok: true, data: { messages: behind.slice(0, opts.limit ?? MAIL_PAGE_SIZE) } } as MessagesResult;
  });
}

/**
 * A full page one, then nothing: once `state.stalled` flips, every refetch
 * hangs forever, so whatever the store reports afterwards is unambiguously
 * its pre-response state (the device `selectAccount`'s synchronous-clear test
 * above uses).
 */
function stalledPageOne() {
  const state = { stalled: false };
  const listMailMessages = vi.fn(async () =>
    state.stalled
      ? new Promise<MessagesResult>(() => {})
      : ({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE) } } as MessagesResult)
  );
  return { state, listMailMessages };
}

describe('MailStore pagination', () => {
  it('appends the page behind the oldest loaded message until the folder runs out', async () => {
    const all = rows(MAIL_PAGE_SIZE * 2 + 30);
    const listMailMessages = pagedFolder(all);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE);
    expect(store.lastPageFull).toBe(true);

    await store.loadOlder();

    // The cursor is the oldest loaded row's own `date`, handed back verbatim.
    expect(listMailMessages).toHaveBeenLastCalledWith('mara', 'INBOX', {
      limit: MAIL_PAGE_SIZE,
      before: all[MAIL_PAGE_SIZE - 1].date
    });
    expect(store.messages.map((m) => m.msgId)).toEqual(all.slice(0, MAIL_PAGE_SIZE * 2).map((r) => r.msgId));
    expect(store.lastPageFull).toBe(true);

    await store.loadOlder();

    // A short page is the end of the folder — the row stops offering itself.
    expect(store.messages.map((m) => m.msgId)).toEqual(all.map((r) => r.msgId));
    expect(store.lastPageFull).toBe(false);
  });

  it('never asks for an older page when the last one came back short', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: rows(12) } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    await store.loadOlder();

    expect(store.lastPageFull).toBe(false);
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('dedupes an older page that overlaps what is already loaded', async () => {
    const first = rows(MAIL_PAGE_SIZE);
    // A row re-indexed between the two reads can come back on BOTH pages
    // (the cursor is a date, and dates are not unique) — appending it twice
    // would give the list two rows with the same `msgId` key.
    const older = [first[MAIL_PAGE_SIZE - 1], ...rows(5, MAIL_PAGE_SIZE)];
    let call = 0;
    const listMailMessages = vi.fn(
      async () => ({ ok: true, data: { messages: call++ === 0 ? first : older } }) as MessagesResult
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    await store.loadOlder();

    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE + 5);
    expect(store.messages.filter((m) => m.msgId === first[MAIL_PAGE_SIZE - 1].msgId)).toHaveLength(1);
  });

  // The two tests below turn on the cursor being dropped the instant the
  // selection changes, not when the new page lands: in that window the list
  // on screen is still the previous one's, and a "Load older" click would
  // page a mailbox nobody is reading from a cursor that means nothing in it.
  it('drops the cursor synchronously on a folder switch, before the new page lands', async () => {
    const { state, listMailMessages } = stalledPageOne();
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    expect(store.lastPageFull).toBe(true);

    state.stalled = true;
    void store.selectFolder('Archive');

    expect(store.lastPageFull).toBe(false);
    listMailMessages.mockClear();
    await store.loadOlder();
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('drops the cursor synchronously on an account switch, before the new page lands', async () => {
    const { state, listMailMessages } = stalledPageOne();
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    expect(store.lastPageFull).toBe(true);

    state.stalled = true;
    void store.selectAccount('zoe');

    expect(store.lastPageFull).toBe(false);
    listMailMessages.mockClear();
    await store.loadOlder();
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('clears the pagination state when the selection vanishes with the account', async () => {
    let accounts: Record<string, any>[] = [rawMara, rawZoe];
    const store = new MailStore(
      fakeApi({
        mailStatus: async () => ({ ok: true, data: { accounts } }) as StatusResult,
        listMailMessages: async () => ({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE) } }) as MessagesResult
      }) as never
    );
    await store.refreshStatus();
    expect(store.lastPageFull).toBe(true);

    accounts = [];
    await store.refreshStatus();

    // No "Load older" row under an emptied list.
    expect(store.selectedAccount).toBeNull();
    expect(store.messages).toEqual([]);
    expect(store.lastPageFull).toBe(false);
  });

  // The cursor is a DATE, so an undated row can never be reached through it:
  // asking `before` anything would return the same page forever. Such a page
  // reads as the end of the folder instead.
  it('stops paginating a page whose rows carry no date', async () => {
    const undated = Array.from({ length: MAIL_PAGE_SIZE }, (_v, i) => ({ msgId: `u${i}`, date: null }));
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: undated } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE);
    expect(store.lastPageFull).toBe(false);
    await store.loadOlder();
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  // Folders keep independent date ranges, and `selectFolder` deliberately
  // leaves the old rows on screen while the new page loads — so a merge that
  // didn't reset first would keep every INBOX row "older" than Archive's
  // newest page and splice one folder's mail into the other's list.
  it('never splices the previous folder’s rows into the new folder’s first page', async () => {
    const inbox = rows(MAIL_PAGE_SIZE, 500);
    const archive = rows(MAIL_PAGE_SIZE);
    const listMailMessages = vi.fn(
      async (_account: string, folder: string) =>
        ({ ok: true, data: { messages: folder === 'INBOX' ? inbox : archive } }) as MessagesResult
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    await store.selectFolder('Archive');

    expect(store.messages.map((m) => m.msgId)).toEqual(archive.map((r) => r.msgId));
    // And the cursor now belongs to Archive, not to the INBOX page it replaced.
    await store.loadOlder();
    expect(listMailMessages).toHaveBeenLastCalledWith('mara', 'Archive', {
      limit: MAIL_PAGE_SIZE,
      before: archive[MAIL_PAGE_SIZE - 1].date
    });
  });

  it('re-reads only the NEWEST page on a live refetch, keeping the appended older pages', async () => {
    const all = rows(MAIL_PAGE_SIZE * 2);
    const listMailMessages = pagedFolder(all);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    await store.loadOlder();
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE * 2);

    // One message arrives at the top and one inside the newest page is
    // deleted — both land, and the older page stays loaded underneath.
    all.unshift({ msgId: 'brand-new', date: isoAt(-1) });
    all.splice(
      all.findIndex((row) => row.msgId === 'm3'),
      1
    );
    store.handleMailMessage({ account: 'mara', path: 'sources/mail/mara/views/messages/m.md' });
    await flush();

    expect(store.messages[0].msgId).toBe('brand-new');
    expect(store.messages.map((m) => m.msgId)).not.toContain('m3');
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE * 2);
    expect(store.messages[store.messages.length - 1].msgId).toBe(`m${MAIL_PAGE_SIZE * 2 - 1}`);
    // The cursor survived the refetch: the next page comes from behind the
    // TAIL, not from behind page one (which would re-read loaded rows
    // forever and never advance).
    await store.loadOlder();
    expect(listMailMessages).toHaveBeenLastCalledWith('mara', 'INBOX', {
      limit: MAIL_PAGE_SIZE,
      before: isoAt(MAIL_PAGE_SIZE * 2 - 1)
    });
  });

  // `lastPageFull` describes the OLDEST loaded page, not the last one
  // fetched: a live refetch re-reads page ONE, which says nothing about
  // what's behind a tail already known to be the end of the folder.
  it('keeps the end-of-folder verdict while the newest page keeps refreshing', async () => {
    const all = rows(MAIL_PAGE_SIZE + 20);
    const listMailMessages = pagedFolder(all);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    await store.loadOlder();
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE + 20);
    expect(store.lastPageFull).toBe(false);

    store.handleMailMessage({ account: 'mara', path: 'sources/mail/mara/views/messages/m.md' });
    await flush();

    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE + 20);
    expect(store.lastPageFull).toBe(false);
  });

  it('drops the appended pages when the newest page comes back short', async () => {
    const all = rows(MAIL_PAGE_SIZE + 50);
    const listMailMessages = pagedFolder(all);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    await store.loadOlder();
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE + 50);

    // A short page one IS the whole folder (the limit is ours, explicitly) —
    // everything held from an older page is gone from the mailbox.
    all.splice(20, all.length);
    store.handleMailMessage({ account: 'mara', path: 'sources/mail/mara/views/messages/m.md' });
    await flush();

    expect(store.messages).toHaveLength(20);
    expect(store.lastPageFull).toBe(false);
  });

  // The push handlers fire `refreshMessages` and walk away, so a switch
  // easily outruns one. A late page must not land: it would put another
  // folder's rows on screen (that half predates pagination) AND point the
  // cursor into that folder — after which "Load older" appends the VISIBLE
  // folder's rows selected by a date from the other one, which is exactly
  // the splice `loadOlder`'s own guard prevents, entered through this door.
  it('discards a live refetch that lands after the folder changed', async () => {
    const inbox = rows(MAIL_PAGE_SIZE, 500);
    const archive = rows(MAIL_PAGE_SIZE);
    let inboxCalls = 0;
    let releaseInbox: (result: MessagesResult) => void = () => {};
    const listMailMessages = vi.fn(async (_account: string, folder: string) => {
      if (folder !== 'INBOX') return { ok: true, data: { messages: archive } } as MessagesResult;
      // The initial load answers at once; the push-driven refetch hangs
      // until this test releases it.
      inboxCalls += 1;
      return inboxCalls === 1
        ? ({ ok: true, data: { messages: inbox } } as MessagesResult)
        : new Promise<MessagesResult>((resolve) => (releaseInbox = resolve));
    });
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    expect(store.messages.map((m) => m.msgId)).toEqual(inbox.map((r) => r.msgId));

    store.handleMailSync({ account: 'mara', phase: 'finished', newMessages: 1 });
    await store.selectFolder('Archive');
    releaseInbox({ ok: true, data: { messages: inbox } } as MessagesResult);
    await flush();

    expect(store.messages.map((m) => m.msgId)).toEqual(archive.map((r) => r.msgId));
    await store.loadOlder();
    expect(listMailMessages).toHaveBeenLastCalledWith('mara', 'Archive', {
      limit: MAIL_PAGE_SIZE,
      before: archive[MAIL_PAGE_SIZE - 1].date
    });
  });

  // Identity ('mara'/'INBOX') reads as unchanged after a round trip through
  // another folder, which is why the guard counts selections instead of
  // comparing them: the list underneath was rebuilt twice, and this response
  // belongs to neither of the two lists that existed since.
  it('discards an older page whose folder changed and changed back mid-flight', async () => {
    const inbox = rows(MAIL_PAGE_SIZE);
    const archive = rows(MAIL_PAGE_SIZE, 500);
    let release: (result: MessagesResult) => void = () => {};
    const listMailMessages = vi.fn(async (_account: string, folder: string, opts: { before?: string } = {}) =>
      opts.before
        ? new Promise<MessagesResult>((resolve) => (release = resolve))
        : ({ ok: true, data: { messages: folder === 'INBOX' ? inbox : archive } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    void store.loadOlder();
    await store.selectFolder('Archive');
    await store.selectFolder('INBOX');
    release({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE, MAIL_PAGE_SIZE) } } as MessagesResult);
    await flush();

    expect(store.messages.map((m) => m.msgId)).toEqual(inbox.map((r) => r.msgId));
  });

  // A dropped response must not drop the in-flight FLAG either: past a
  // switch the flag belongs to whichever call the new list started.
  it('leaves the in-flight flag to the newer call when a pre-switch response lands', async () => {
    const inbox = rows(MAIL_PAGE_SIZE);
    const archive = rows(MAIL_PAGE_SIZE, 500);
    const pending: ((result: MessagesResult) => void)[] = [];
    const listMailMessages = vi.fn(async (_account: string, folder: string, opts: { before?: string } = {}) =>
      opts.before
        ? new Promise<MessagesResult>((resolve) => pending.push(resolve))
        : ({ ok: true, data: { messages: folder === 'INBOX' ? inbox : archive } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    void store.loadOlder();
    await store.selectFolder('Archive');
    void store.loadOlder();
    expect(store.loadingOlder).toBe(true);

    pending[0]({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE, MAIL_PAGE_SIZE) } } as MessagesResult);
    await flush();

    // Archive's own request is still out, so the row stays disabled.
    expect(store.loadingOlder).toBe(true);
    expect(store.messages.map((m) => m.msgId)).toEqual(archive.map((r) => r.msgId));
  });

  // No selection change here — the tail simply stopped existing while the
  // request for the page behind it was out.
  it('discards an older page whose tail a short live refetch had already dropped', async () => {
    const full = rows(MAIL_PAGE_SIZE);
    let shrunk = false;
    let release: (result: MessagesResult) => void = () => {};
    const listMailMessages = vi.fn(async (_account: string, _folder: string, opts: { before?: string } = {}) =>
      opts.before
        ? new Promise<MessagesResult>((resolve) => (release = resolve))
        : ({ ok: true, data: { messages: shrunk ? rows(12) : full } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    void store.loadOlder();
    shrunk = true;
    store.handleMailMessage({ account: 'mara', path: 'sources/mail/mara/views/messages/m.md' });
    await flush();
    expect(store.messages).toHaveLength(12);

    release({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE, MAIL_PAGE_SIZE) } } as MessagesResult);
    await flush();

    expect(store.messages).toHaveLength(12);
    expect(store.lastPageFull).toBe(false);
    // …and the row isn't left stuck disabled by the response it dropped.
    expect(store.loadingOlder).toBe(false);
  });

  it('discards an older page that lands after the folder changed', async () => {
    const inbox = rows(MAIL_PAGE_SIZE);
    const archive = rows(3, 500);
    let release: (result: MessagesResult) => void = () => {};
    const listMailMessages = vi.fn(
      async (_account: string, folder: string, opts: { before?: string } = {}) =>
        opts.before
          ? new Promise<MessagesResult>((resolve) => (release = resolve))
          : ({ ok: true, data: { messages: folder === 'INBOX' ? inbox : archive } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    void store.loadOlder();
    await store.selectFolder('Archive');
    release({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE, MAIL_PAGE_SIZE) } } as MessagesResult);
    await flush();

    expect(store.messages.map((m) => m.msgId)).toEqual(archive.map((r) => r.msgId));
  });

  it('flags the in-flight load and ignores a second click while it runs', async () => {
    let release: (result: MessagesResult) => void = () => {};
    const listMailMessages = vi.fn(
      async (_account: string, _folder: string, opts: { before?: string } = {}) =>
        opts.before
          ? new Promise<MessagesResult>((resolve) => (release = resolve))
          : ({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE) } } as MessagesResult)
    );
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    void store.loadOlder();
    expect(store.loadingOlder).toBe(true);
    void store.loadOlder();
    expect(listMailMessages).toHaveBeenCalledTimes(1);

    release({ ok: true, data: { messages: rows(5, MAIL_PAGE_SIZE) } } as MessagesResult);
    await flush();

    expect(store.loadingOlder).toBe(false);
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE + 5);
  });
});

/** One `search_mail` row: a `list_mail_messages` row plus the backend-truncated `snippet`. */
function hit(msgId: string, snippet: string | null = '…matched body text…'): Record<string, any> {
  return { msgId, subject: `Subject ${msgId}`, date: isoAt(0), snippet };
}

/** A search that never answers until the test releases it, per query. */
function stalledSearch() {
  const pending = new Map<string, (result: MessagesResult) => void>();
  const searchMail = vi.fn(
    async (_account: string, query: string) =>
      new Promise<MessagesResult>((resolve) => pending.set(query, resolve))
  );
  const release = (query: string, ...rows: Record<string, any>[]) =>
    pending.get(query)!({ ok: true, data: { messages: rows } } as MessagesResult);
  return { searchMail, release };
}

describe('MailStore search', () => {
  it('loads hits for the selected account and leaves the folder list untouched', async () => {
    const searchMail = vi.fn(
      async () => ({ ok: true, data: { messages: [hit('s1'), hit('s2')] } }) as MessagesResult
    );
    const listMailMessages = vi.fn(
      async () => ({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE) } }) as MessagesResult
    );
    const store = new MailStore(fakeApi({ searchMail, listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    await store.search('  invoice  ');

    // The typed text is trimmed and passed through verbatim otherwise — the
    // backend owns tokenizing it, and `limit` is left to the action's default.
    expect(searchMail).toHaveBeenCalledWith('mara', 'invoice');
    expect(store.searchResults.map((h) => h.msgId)).toEqual(['s1', 's2']);
    expect(store.searchResults[0].snippet).toBe('…matched body text…');
    expect(store.searchQuery).toBe('invoice');
    // Nothing about the folder listing moved: same rows, same pagination
    // state, and no refetch of it.
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE);
    expect(store.lastPageFull).toBe(true);
    expect(store.loadingOlder).toBe(false);
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('defaults a null snippet to an empty string', async () => {
    const store = new MailStore(
      fakeApi({
        searchMail: async () => ({ ok: true, data: { messages: [hit('s1', null)] } }) as MessagesResult
      }) as never
    );
    await store.refreshStatus();

    await store.search('invoice');

    // `snippet` is `allow_nil?: true` on the action; the row's snippet line
    // must not render the word "null".
    expect(store.searchResults[0].snippet).toBe('');
  });

  it('short-circuits a blank query without an RPC', async () => {
    const { searchMail } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();

    await store.search('');
    await store.search('   ');

    expect(searchMail).not.toHaveBeenCalled();
    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');
  });

  it('clears loaded hits when the query is emptied, without refetching the folder', async () => {
    const listMailMessages = vi.fn(
      async () => ({ ok: true, data: { messages: rows(MAIL_PAGE_SIZE) } }) as MessagesResult
    );
    const store = new MailStore(
      fakeApi({
        listMailMessages,
        searchMail: async () => ({ ok: true, data: { messages: [hit('s1')] } }) as MessagesResult
      }) as never
    );
    await store.refreshStatus();
    await store.search('invoice');
    listMailMessages.mockClear();

    await store.search('  ');

    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');
    // The folder list was never disturbed, so restoring it costs nothing.
    expect(store.messages).toHaveLength(MAIL_PAGE_SIZE);
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('flags a failed search instead of reporting an empty mailbox', async () => {
    let fails = true;
    const store = new MailStore(
      fakeApi({
        searchMail: async () =>
          (fails
            ? { ok: false, error: 'workspace_changed' }
            : { ok: true, data: { messages: [hit('s1')] } }) as MessagesResult
      }) as never
    );
    await store.refreshStatus();

    await store.search('invoice');

    // The query IS recorded: the route reads `searchQuery === typed text` as
    // "the answer is in", so leaving it unset would spin "Searching…" forever.
    expect(store.searchQuery).toBe('invoice');
    expect(store.searchResults).toEqual([]);
    expect(store.searchFailed).toBe(true);

    fails = false;
    await store.search('invoice');

    expect(store.searchFailed).toBe(false);
    expect(store.searchResults).toHaveLength(1);

    store.clearSearch();
    expect(store.searchFailed).toBe(false);
  });

  it('drops an older query whose response lands after a newer one', async () => {
    const { searchMail, release } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();

    void store.search('inv');
    void store.search('invoice');
    release('invoice', hit('newer'));
    await flush();
    release('inv', hit('older'));
    await flush();

    expect(store.searchResults.map((h) => h.msgId)).toEqual(['newer']);
    expect(store.searchQuery).toBe('invoice');
  });

  it('drops a response that lands after the query was cleared', async () => {
    const { searchMail, release } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();

    void store.search('invoice');
    store.clearSearch();
    release('invoice', hit('s1'));
    await flush();

    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');
  });

  it('drops the hits synchronously on an account switch, and the response that follows', async () => {
    const { searchMail, release } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();
    void store.search('invoice');
    release('invoice', hit('s1'));
    await flush();
    expect(store.searchQuery).toBe('invoice');

    void store.search('later');
    void store.selectAccount('zoe');

    // Gone before the switch's own fetches even resolve — a hit belongs to
    // the account it was found in.
    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');

    release('later', hit('s1'));
    await flush();

    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');
  });

  // The selection epoch guard, exercised where the token guard can't reach:
  // a folder switch doesn't clear the search, so only the epoch stands
  // between a response and a list it no longer belongs to.
  it('drops a response for a selection that moved while it was out', async () => {
    const { searchMail, release } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();

    void store.search('invoice');
    await store.selectFolder('Archive');
    release('invoice', hit('s1'));
    await flush();

    expect(store.searchResults).toEqual([]);
    expect(store.searchQuery).toBe('');
  });

  // `handleMailStatus` fires several times per poll cycle and refetches the
  // folder list each time. The search must ride through it: `#ensureSelection`
  // returns early while the account still exists, so neither the loaded hits
  // nor an in-flight one are invalidated.
  it('is not disturbed by a mail_status push for the selected account', async () => {
    const { searchMail, release } = stalledSearch();
    const store = new MailStore(fakeApi({ searchMail }) as never);
    await store.refreshStatus();

    void store.search('invoice');
    store.handleMailStatus(pushFor(rawMara));
    await flush();
    release('invoice', hit('s1'));
    await flush();

    expect(store.searchResults.map((h) => h.msgId)).toEqual(['s1']);
    expect(store.searchQuery).toBe('invoice');

    store.handleMailStatus(pushFor(rawMara));
    await flush();

    expect(store.searchResults.map((h) => h.msgId)).toEqual(['s1']);
    expect(store.searchQuery).toBe('invoice');
  });

  it('does nothing when no account is selected', async () => {
    const { searchMail } = stalledSearch();
    const store = new MailStore(
      fakeApi({ searchMail, mailStatus: async () => ({ ok: true, data: { accounts: [] } }) }) as never
    );
    await store.refreshStatus();

    await store.search('invoice');

    expect(searchMail).not.toHaveBeenCalled();
    expect(store.searchResults).toEqual([]);
  });
});

describe('MailStore.select', () => {
  it('loads detail from the selected account on success', async () => {
    const message = { frontmatter: { subject: 'Hi' }, body: 'Body text', path: 'sources/mail/mara/views/messages/m1.md' };
    const getMailMessage = vi.fn(async () => ({ ok: true, data: { message } }) as DetailResult);
    const store = new MailStore(fakeApi({ getMailMessage }) as never);
    await store.refreshStatus();

    await store.select('m1');

    expect(getMailMessage).toHaveBeenCalledWith('mara', 'm1');
    expect(store.selected).toEqual({
      frontmatter: { subject: 'Hi' },
      body: 'Body text',
      path: 'sources/mail/mara/views/messages/m1.md',
      html: null,
      externalContent: false,
      senderTrusted: false
    });
    expect(store.loading).toBe(false);
  });

  it('normalizes the html/trust fields off their string snake keys', async () => {
    const message = {
      frontmatter: {},
      body: 'b',
      path: 'p',
      html: '<p>Hi</p>',
      external_content: true,
      sender_trusted: true
    };
    const getMailMessage = vi.fn(async () => ({ ok: true, data: { message } }) as DetailResult);
    const store = new MailStore(fakeApi({ getMailMessage }) as never);
    await store.refreshStatus();

    await store.select('m1');

    expect(store.selected?.html).toBe('<p>Hi</p>');
    expect(store.selected?.externalContent).toBe(true);
    expect(store.selected?.senderTrusted).toBe(true);
  });

  it('no-ops without a selected account', async () => {
    const getMailMessage = vi.fn(async () => ({ ok: true, data: { message: {} } }) as DetailResult);
    const store = new MailStore(fakeApi({ getMailMessage }) as never);

    await store.select('m1');

    expect(getMailMessage).not.toHaveBeenCalled();
  });

  it('leaves selected untouched (loading reset) on failure', async () => {
    const store = new MailStore(
      fakeApi({ getMailMessage: async () => ({ ok: false, error: 'not_found' }) }) as never
    );
    await store.refreshStatus();

    await store.select('missing');

    expect(store.selected).toBeNull();
    expect(store.loading).toBe(false);
  });
});

describe('MailStore.syncNow', () => {
  it('returns null on success and the error code on failure', async () => {
    const ok = new MailStore(fakeApi({}) as never);
    expect(await ok.syncNow('mara', 3)).toBeNull();

    const failing = new MailStore(
      fakeApi({ mailSyncNow: async () => ({ ok: false, error: 'mailbox_replaced' }) }) as never
    );
    expect(await failing.syncNow('mara', 3)).toBe('mailbox_replaced');
  });
});

describe('MailStore push handlers (account filtering)', () => {
  it('handleMailStatus upserts the pushed account by slug', async () => {
    const store = new MailStore(fakeApi({}) as never);
    await store.refreshStatus();

    store.handleMailStatus(pushFor({ ...rawZoe, state: 'syncing' }));

    expect(store.accounts.find((a) => a.account === 'zoe')?.state).toBe('syncing');
    expect(store.accounts).toHaveLength(2);
  });

  it('handleMailStatus appends a previously unknown account in slug order', async () => {
    const store = new MailStore(fakeApi({}) as never);
    await store.refreshStatus();

    store.handleMailStatus(pushFor({ ...rawZoe, account: 'aaa-new' }));

    expect(store.accounts.map((a) => a.account)).toEqual(['aaa-new', 'mara', 'zoe']);
  });

  it('handleMailStatus refetches lists only for the SELECTED account', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    store.handleMailStatus(pushFor(rawZoe));
    await flush();
    expect(listMailMessages).not.toHaveBeenCalled();

    store.handleMailStatus(pushFor(rawMara));
    await flush();
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  it('handleMailStatus notifies onMailStatus listeners for every account', async () => {
    const store = new MailStore(fakeApi({}) as never);
    await store.refreshStatus();
    const seen: string[] = [];
    store.onMailStatus((payload) => seen.push(payload.account));

    store.handleMailStatus(pushFor(rawZoe));
    store.handleMailStatus(pushFor(rawMara));

    expect(seen).toEqual(['zoe', 'mara']);
  });

  it('handleMailSync refetches only a finished pass of the selected account', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    store.handleMailSync({ account: 'zoe', phase: 'finished', newMessages: 1 });
    store.handleMailSync({ account: 'mara', phase: 'started', newMessages: 0 });
    await flush();
    expect(listMailMessages).not.toHaveBeenCalled();

    store.handleMailSync({ account: 'mara', phase: 'finished', newMessages: 1 });
    await flush();
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  it('handleMailMessage refetches only for the selected account', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    store.handleMailMessage({ account: 'zoe', path: 'sources/mail/zoe/views/messages/m.md' });
    await flush();
    expect(listMailMessages).not.toHaveBeenCalled();

    store.handleMailMessage({ account: 'mara', path: 'sources/mail/mara/views/messages/m.md' });
    await flush();
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  it('handleMailDraft refetches the drafts list for ANY account', async () => {
    const drafts = [{ account: 'zoe', name: 'reply.md', path: 'sources/mail/zoe/drafts/reply.md' }];
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts } }) as DraftsResult);
    const store = new MailStore(fakeApi({ listMailDrafts }) as never);
    await store.refreshStatus();

    // Unlike folders/messages, the drafts list is workspace-wide (every
    // account in one call), so a BACKGROUND account's draft is refetched
    // too — `selectedDrafts` narrows it for display.
    store.handleMailDraft({ account: 'zoe' });
    await flush();
    expect(listMailDrafts).toHaveBeenCalledTimes(1);
    expect(store.drafts.map((d) => d.account)).toEqual(['zoe']);

    store.handleMailDraft({ account: 'mara' });
    await flush();
    expect(listMailDrafts).toHaveBeenCalledTimes(2);
  });
});

describe('resupplyCredentials', () => {
  const missing = (raw: Record<string, any>) => normalizeMailAccountStatus({ ...raw, credential: 'missing' });

  it('resolves 0 outside the desktop app without touching the keychain', async () => {
    const count = await resupplyCredentials([missing(rawMara)], fakeApi({}) as never);

    expect(count).toBe(0);
    expect(keychainGet).not.toHaveBeenCalled();
  });

  it('looks each account up under <slug>:imap and resupplies every one with a stored secret', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockImplementation(async (_ws, key) =>
      key === 'mara:imap' ? 's3cret-mara' : key === 'zoe:imap' ? 's3cret-zoe' : null
    );
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const count = await resupplyCredentials([missing(rawMara), missing(rawZoe)], { setMailCredential } as never);

    expect(count).toBe(2);
    expect(keychainGet).toHaveBeenCalledWith('ws-1', 'mara:imap');
    expect(keychainGet).toHaveBeenCalledWith('ws-1', 'zoe:imap');
    expect(setMailCredential).toHaveBeenCalledWith('mara', 's3cret-mara', expect.any(Number));
    expect(setMailCredential).toHaveBeenCalledWith('zoe', 's3cret-zoe', expect.any(Number));
  });

  it('skips accounts whose credential is already present (self-terminating) and those without a stored secret', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockImplementation(async (_ws, key) => (key === 'zoe:imap' ? 's3cret-zoe' : null));
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const count = await resupplyCredentials(
      [normalizeMailAccountStatus(rawMara), missing(rawZoe), missing({ ...rawZoe, account: 'unstored' })],
      { setMailCredential } as never
    );

    expect(count).toBe(1);
    expect(setMailCredential).toHaveBeenCalledTimes(1);
    expect(setMailCredential).toHaveBeenCalledWith('zoe', 's3cret-zoe', expect.any(Number));
  });

  // Spec G §Configuration & credentials: the SMTP secret is a SEPARATE
  // keychain entry (`<slug>:smtp`), resupplied on the same restart-recovery
  // path as the IMAP one and handed over with `kind: 'smtp'`.
  it('resupplies the smtp entry independently, under <slug>:smtp with kind smtp', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockImplementation(async (_ws, key) =>
      key === 'mara:imap' ? 'imap-secret' : key === 'mara:smtp' ? 'smtp-secret' : null
    );
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const count = await resupplyCredentials(
      [
        normalizeMailAccountStatus({
          ...rawMara,
          credential: 'missing',
          smtp_configured: true,
          smtp_credential: 'missing'
        })
      ],
      { setMailCredential } as never
    );

    expect(count).toBe(2);
    expect(keychainGet).toHaveBeenCalledWith('ws-1', 'mara:smtp');
    expect(setMailCredential).toHaveBeenCalledWith('mara', 'imap-secret', expect.any(Number));
    expect(setMailCredential).toHaveBeenCalledWith('mara', 'smtp-secret', expect.any(Number), 'smtp');
  });

  it('resupplies smtp even when the imap credential is already present', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockImplementation(async (_ws, key) => (key === 'mara:smtp' ? 'smtp-secret' : null));
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const count = await resupplyCredentials(
      [normalizeMailAccountStatus({ ...rawMara, smtp_configured: true, smtp_credential: 'missing' })],
      { setMailCredential } as never
    );

    expect(count).toBe(1);
    expect(setMailCredential).toHaveBeenCalledTimes(1);
    expect(setMailCredential).toHaveBeenCalledWith('mara', 'smtp-secret', expect.any(Number), 'smtp');
  });

  it('never touches the smtp entry for a push-only account or one whose smtp secret is already present', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockResolvedValue('any-secret');
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    await resupplyCredentials(
      [
        normalizeMailAccountStatus(rawMara), // push-only: smtp_credential "n/a"
        normalizeMailAccountStatus({ ...rawZoe, smtp_configured: true, smtp_credential: 'present' })
      ],
      { setMailCredential } as never
    );

    expect(keychainGet).not.toHaveBeenCalledWith('ws-1', 'mara:smtp');
    expect(keychainGet).not.toHaveBeenCalledWith('ws-1', 'zoe:smtp');
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('skips invalid and unconfigured entries outright', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const count = await resupplyCredentials(
      [
        normalizeMailAccountStatus({ account: 'broken', valid: false, state: 'invalid_config', reason: 'x' }),
        normalizeMailAccountStatus({ ...rawMara, configured: false, credential: 'missing' })
      ],
      { setMailCredential } as never
    );

    expect(count).toBe(0);
    expect(keychainGet).not.toHaveBeenCalled();
  });
});

describe('MailStore.applyOps', () => {
  it('passes the op maps through verbatim (snake keys) and refetches lists on success', async () => {
    const applyMailOps = vi.fn(
      async () => ({ ok: true, data: { results: [{ op: 0, result: 'accepted', reason: null }] } }) as OpsResult
    );
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ applyMailOps, listMailMessages }) as never);
    await store.refreshStatus();
    listMailMessages.mockClear();

    const op = { op: 'move', msg_id: 'm1', from: 'INBOX', to: 'Archive' };
    const results = await store.applyOps('mara', [op], 7);
    await flush();

    expect(applyMailOps).toHaveBeenCalledWith('mara', [op], 7);
    expect(results).toEqual([{ op: 0, result: 'accepted', reason: null }]);
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX', { limit: MAIL_PAGE_SIZE });
  });

  it('synthesizes per-op rejections when the RPC itself fails', async () => {
    const store = new MailStore(
      fakeApi({ applyMailOps: async () => ({ ok: false, error: 'workspace_changed' }) }) as never
    );

    const results = await store.applyOps('mara', [{ op: 'move' }, { op: 'flag' }], 7);

    expect(results).toEqual([
      { op: 0, result: 'rejected', reason: 'workspace_changed' },
      { op: 1, result: 'rejected', reason: 'workspace_changed' }
    ]);
  });
});

describe('normalizeMailDraft + MailStore.refreshDrafts', () => {
  const rawDraft = {
    account: 'mara',
    name: 'reply.md',
    path: 'sources/mail/mara/drafts/reply.md',
    status_display: 'draft',
    notice: null,
    parsed_recipients: {
      to: [{ name: null, email: 'alex@example.com' }],
      cc: [],
      bcc: [],
      subject: 'Re: Kickoff'
    }
  };

  it('normalizes a parsed draft entry', () => {
    expect(normalizeMailDraft(rawDraft)).toEqual({
      account: 'mara',
      name: 'reply.md',
      path: 'sources/mail/mara/drafts/reply.md',
      statusDisplay: 'draft',
      notice: null,
      pushed: false,
      opId: null,
      recipients: {
        to: [{ name: null, email: 'alex@example.com' }],
        cc: [],
        bcc: [],
        subject: 'Re: Kickoff'
      }
    });
  });

  // `pushed` is a separate FACT, not a state (spec G §Display projection) —
  // a completed push riding alongside a `send_review` primary state.
  it('maps the pushed badge fact and the op id of a resolvable row', () => {
    const row = normalizeMailDraft({
      ...rawDraft,
      status_display: 'send_review',
      notice: 'gmail_sent_checked_empty',
      pushed: true,
      op_id: 'op-7'
    });

    expect(row.statusDisplay).toBe('send_review');
    expect(row.pushed).toBe(true);
    expect(row.opId).toBe('op-7');
  });

  it('normalizes an invalid draft entry to {invalid}', () => {
    const invalid = normalizeMailDraft({ ...rawDraft, parsed_recipients: { invalid: 'link_unsafe' } });
    expect(invalid.recipients).toEqual({ invalid: 'link_unsafe' });
  });

  it('refreshDrafts populates the normalized list', async () => {
    const store = new MailStore(
      fakeApi({ listMailDrafts: async () => ({ ok: true, data: { drafts: [rawDraft] } }) }) as never
    );

    await store.refreshDrafts();

    expect(store.drafts).toHaveLength(1);
    expect(store.drafts[0].name).toBe('reply.md');
  });

  // `list_mail_drafts` is workspace-wide (every account's drafts in one
  // list), but the mail pane's Drafts count belongs to the account being
  // read — a count including a second account's drafts is simply wrong.
  it('selectedDrafts narrows the workspace-wide list to the selected account', async () => {
    const drafts = [rawDraft, { ...rawDraft, account: 'zoe', name: 'zoe-reply.md' }];
    const store = new MailStore(
      fakeApi({ listMailDrafts: async () => ({ ok: true, data: { drafts } }) }) as never
    );
    await store.refreshStatus();
    await store.refreshDrafts();

    expect(store.selectedAccount).toBe('mara');
    expect(store.selectedDrafts.map((d) => d.name)).toEqual(['reply.md']);

    await store.selectAccount('zoe');
    expect(store.selectedDrafts.map((d) => d.name)).toEqual(['zoe-reply.md']);
  });
});

describe('MailStore.pushDraft', () => {
  it('hashes the exact fetched bytes (backend content_hash encoding) and pushes bound to them', async () => {
    const content = '---\nto: [a@b.c]\nsubject: "S"\n---\nBody.\n';
    const getMailDraft = vi.fn(
      async () => ({ ok: true, data: { content, path: 'sources/mail/mara/drafts/reply.md' } }) as DraftContentResult
    );
    const pushDraftToMailbox = vi.fn(async () => ({ ok: true, data: { state: 'pushed' } }) as PushResult);
    const store = new MailStore(fakeApi({ getMailDraft, pushDraftToMailbox }) as never);

    const outcome = await store.pushDraft('mara', 'reply.md', 7);

    const expectedHash = await sha256Hex(content);
    // Pin the encoding itself, not just "some string": lowercase hex sha256.
    expect(expectedHash).toMatch(/^[0-9a-f]{64}$/);
    expect(getMailDraft).toHaveBeenCalledWith('mara', 'reply.md');
    expect(pushDraftToMailbox).toHaveBeenCalledWith('mara', 'reply.md', expectedHash, 7);
    expect(outcome).toEqual({ state: 'pushed' });
  });

  it('surfaces a fetch failure without pushing', async () => {
    const pushDraftToMailbox = vi.fn(async () => ({ ok: true, data: { state: 'pushed' } }) as PushResult);
    const store = new MailStore(
      fakeApi({ getMailDraft: async () => ({ ok: false, error: 'link_unsafe' }), pushDraftToMailbox }) as never
    );

    const outcome = await store.pushDraft('mara', 'reply.md', 7);

    expect(outcome).toEqual({ error: 'link_unsafe' });
    expect(pushDraftToMailbox).not.toHaveBeenCalled();
  });

  it('surfaces a push failure and still refetches the drafts list', async () => {
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult);
    const store = new MailStore(
      fakeApi({
        getMailDraft: async () => ({ ok: true, data: { content: 'x', path: 'p' } }),
        pushDraftToMailbox: async () => ({ ok: false, error: 'content_changed' }),
        listMailDrafts
      }) as never
    );

    const outcome = await store.pushDraft('mara', 'reply.md', 7);
    await flush();

    expect(outcome).toEqual({ error: 'content_changed' });
    expect(listMailDrafts).toHaveBeenCalled();
  });
});

describe('MailStore.saveDraft', () => {
  it('creates with a null base hash, then hands back the minted name and the hash of what landed', async () => {
    const content = '---\nto: ["a@b.c"]\ncc: []\nbcc: []\nsubject: "S"\n---\nBody.';
    const writeMailDraft = vi.fn(
      async () => ({ ok: true, data: { name: '20260729T150000-s.md', saved: true } }) as WriteDraftResult
    );
    const getMailDraft = vi.fn(
      async () => ({ ok: true, data: { content, path: 'sources/mail/mara/drafts/x.md' } }) as DraftContentResult
    );
    const store = new MailStore(fakeApi({ writeMailDraft, getMailDraft }) as never);

    const outcome = await store.saveDraft('mara', null, content, null, 7);

    expect(writeMailDraft).toHaveBeenCalledWith('mara', null, content, null, 7);
    // The read-back is what the NEXT save's CAS is bound to — not the bytes
    // this client believes it just wrote.
    expect(getMailDraft).toHaveBeenCalledWith('mara', '20260729T150000-s.md');
    expect(outcome).toEqual({ name: '20260729T150000-s.md', hash: await sha256Hex(content), content });
  });

  it('reports the bytes on disk when another writer got in between', async () => {
    const written = '---\nto: ["a@b.c"]\ncc: []\nbcc: []\nsubject: "mine"\n---\nMine.';
    const onDisk = '---\nto: ["a@b.c"]\ncc: []\nbcc: []\nsubject: "theirs"\n---\nTheirs.';
    const store = new MailStore(
      fakeApi({
        writeMailDraft: async () => ({ ok: true, data: { name: 'reply.md', saved: true } }),
        getMailDraft: async () => ({ ok: true, data: { content: onDisk, path: 'p' } })
      }) as never
    );

    const outcome = await store.saveDraft('mara', 'reply.md', written, 'a'.repeat(64), 7);

    expect(outcome).toEqual({ name: 'reply.md', hash: await sha256Hex(onDisk), content: onDisk });
  });

  it('falls back to hashing what it wrote when the read-back fails — the save DID happen', async () => {
    const content = '---\nto: ["a@b.c"]\ncc: []\nbcc: []\nsubject: "S"\n---\nBody.';
    const store = new MailStore(
      fakeApi({
        writeMailDraft: async () => ({ ok: true, data: { name: 'reply.md', saved: true } }),
        getMailDraft: async () => ({ ok: false, error: 'not_found' })
      }) as never
    );

    const outcome = await store.saveDraft('mara', 'reply.md', content, 'a'.repeat(64), 7);

    expect(outcome).toEqual({ name: 'reply.md', hash: await sha256Hex(content), content });
  });

  it('surfaces a refused write verbatim and never reads back', async () => {
    const getMailDraft = vi.fn(async () => ({ ok: true, data: { content: '', path: '' } }) as DraftContentResult);
    const store = new MailStore(
      fakeApi({ writeMailDraft: async () => ({ ok: false, error: 'content_changed' }), getMailDraft }) as never
    );

    expect(await store.saveDraft('mara', 'reply.md', 'x', 'stale', 7)).toEqual({ error: 'content_changed' });
    expect(getMailDraft).not.toHaveBeenCalled();
  });

  it('refetches the drafts list so the row (and its ledger state) follows the write', async () => {
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult);
    const store = new MailStore(fakeApi({ listMailDrafts }) as never);

    await store.saveDraft('mara', 'reply.md', 'x', 'a'.repeat(64), 7);
    await flush();

    expect(listMailDrafts).toHaveBeenCalled();
  });
});

describe('MailStore.ownAddress', () => {
  const settings = (smtp: Record<string, any> | null): AccountSettingsResult =>
    ({
      ok: true,
      data: { account: { host: 'imap.example.com', port: 993, username: 'login@example.com', smtp } }
    }) as AccountSettingsResult;

  it('prefers the configured sending identity over the IMAP login', async () => {
    const store = new MailStore(
      fakeApi({ getMailAccountSettings: async () => settings({ from: 'mara@example.com' }) }) as never
    );

    expect(await store.ownAddress('mara')).toBe('mara@example.com');
  });

  it('falls back to the IMAP login for a push-only account with no smtp block', async () => {
    const store = new MailStore(fakeApi({ getMailAccountSettings: async () => settings(null) }) as never);

    expect(await store.ownAddress('mara')).toBe('login@example.com');
  });

  it('is null when neither is an address — a bare mailbox login is not one', async () => {
    // Dovecot/Cyrus/local mailboxes log in as `mara`, not `mara@…`. Returning
    // that would be a value reply-all could never match against a recipient.
    const store = new MailStore(
      fakeApi({
        getMailAccountSettings: async () =>
          ({
            ok: true,
            data: { account: { host: 'localhost', port: 3993, username: 'mara', smtp: null } }
          }) as AccountSettingsResult
      }) as never
    );

    expect(await store.ownAddress('mara')).toBeNull();
  });

  it('caches per account, and a mail_status push drops that account’s entry only', async () => {
    const getMailAccountSettings = vi.fn(async (account: string) =>
      settings({ from: `${account}@example.com` })
    );
    const store = new MailStore(fakeApi({ getMailAccountSettings }) as never);

    await store.ownAddress('mara');
    await store.ownAddress('mara');
    await store.ownAddress('zoe');
    expect(getMailAccountSettings).toHaveBeenCalledTimes(2);

    // A settings reload is the one thing that can move `smtp.from`, and it
    // always broadcasts a status push.
    store.handleMailStatus(pushFor(rawMara));
    await store.ownAddress('mara');
    await store.ownAddress('zoe');
    expect(getMailAccountSettings).toHaveBeenCalledTimes(3);
  });

  it('does not cache a failed read', async () => {
    const getMailAccountSettings = vi.fn(async () => ({ ok: false, error: 'not_found' }) as AccountSettingsResult);
    const store = new MailStore(fakeApi({ getMailAccountSettings }) as never);

    expect(await store.ownAddress('mara')).toBeNull();
    expect(await store.ownAddress('mara')).toBeNull();
    expect(getMailAccountSettings).toHaveBeenCalledTimes(2);
  });
});

describe('MailStore.draftReview', () => {
  it('normalizes the one-buffer review snapshot (camelCased typed fields, snake-keyed nested maps)', async () => {
    const getMailDraftReview = vi.fn(async () => ({ ok: true, data: rawReview }) as ReviewResult);
    const store = new MailStore(fakeApi({ getMailDraftReview }) as never);

    const review = await store.draftReview('mara', 'reply.md');

    expect(getMailDraftReview).toHaveBeenCalledWith('mara', 'reply.md');
    expect(review).toEqual({
      content: rawReview.content,
      contentHash: rawReview.contentHash,
      reviewFingerprint: rawReview.reviewFingerprint,
      recipients: {
        to: [{ name: null, email: 'alex@example.com' }],
        cc: [{ name: 'Bo', email: 'bo@example.com' }],
        bcc: []
      },
      subject: 'Re: Kickoff',
      attachments: [{ filename: 'deck.pdf', path: 'notes/deck.pdf', bytes: 2048 }],
      threading: { inReplyTo: '<m1@example.com>', references: ['<m0@example.com>'] },
      threadingWarning: false,
      identity: { from: 'mara@example.com', fromName: 'Mara Vance', account: 'mara' },
      smtpConfigured: true
    });
  });

  it('surfaces the error code', async () => {
    const store = new MailStore(
      fakeApi({ getMailDraftReview: async () => ({ ok: false, error: 'invalid_draft' }) }) as never
    );

    expect(await store.draftReview('mara', 'reply.md')).toEqual({ error: 'invalid_draft' });
  });
});

describe('normalizeMailDraftReview', () => {
  it('degrades an absent threading/identity/recipients payload instead of throwing', () => {
    const review = normalizeMailDraftReview({ content: 'x', contentHash: 'h', smtpConfigured: false });

    expect(review).toEqual({
      content: 'x',
      contentHash: 'h',
      reviewFingerprint: null,
      recipients: { to: [], cc: [], bcc: [] },
      subject: '',
      attachments: [],
      threading: null,
      threadingWarning: false,
      identity: { from: null, fromName: null, account: '' },
      smtpConfigured: false
    });
  });
});

describe('MailStore.sendDraft', () => {
  // The one-buffer contract (spec G §UI): everything the human confirmed
  // came out of ONE review read, so the send carries THAT read's tokens —
  // never a fresh fetch, never a re-hash.
  it("passes the review's hash and fingerprint verbatim and never re-reads the draft", async () => {
    const sendDraft = vi.fn(async () => ({ ok: true, data: { state: 'sent' } }) as SendResult);
    const getMailDraft = vi.fn(
      async () => ({ ok: true, data: { content: 'other', path: 'p' } }) as DraftContentResult
    );
    const store = new MailStore(fakeApi({ sendDraft, getMailDraft }) as never);

    const outcome = await store.sendDraft('mara', 'reply.md', 'hash-from-review', 'fp-from-review', 7);

    expect(sendDraft).toHaveBeenCalledWith('mara', 'reply.md', 'hash-from-review', 'fp-from-review', 7);
    expect(getMailDraft).not.toHaveBeenCalled();
    expect(outcome).toEqual({ state: 'sent' });
  });

  it('refetches the drafts list on success AND on failure, surfacing the error code', async () => {
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult);
    const store = new MailStore(
      fakeApi({ sendDraft: async () => ({ ok: false, error: 're_review_required' }), listMailDrafts }) as never
    );

    const outcome = await store.sendDraft('mara', 'reply.md', 'h', 'fp', 7);
    await flush();

    expect(outcome).toEqual({ error: 're_review_required' });
    expect(listMailDrafts).toHaveBeenCalled();
  });
});

describe('MailStore.resolveSendReview / retrySentCopy', () => {
  it('resolveSendReview passes the verdict through and refreshes the drafts list', async () => {
    const resolveSendReview = vi.fn(async () => ({ ok: true, data: { resolved: true } }) as ResolveResult);
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult);
    const store = new MailStore(fakeApi({ resolveSendReview, listMailDrafts }) as never);

    const error = await store.resolveSendReview('mara', 'op-7', 'not_sent', 7);
    await flush();

    expect(resolveSendReview).toHaveBeenCalledWith('mara', 'op-7', 'not_sent', 7);
    expect(error).toBeNull();
    expect(listMailDrafts).toHaveBeenCalled();
  });

  it('resolveSendReview resolves the error code on failure', async () => {
    const store = new MailStore(
      fakeApi({ resolveSendReview: async () => ({ ok: false, error: 'not_reviewable' }) }) as never
    );

    expect(await store.resolveSendReview('mara', 'op-7', 'sent', 7)).toBe('not_reviewable');
  });

  it('retrySentCopy re-runs the Sent copy and refreshes the drafts list', async () => {
    const retrySentCopy = vi.fn(async () => ({ ok: true, data: { retried: true } }) as RetryResult);
    const listMailDrafts = vi.fn(async () => ({ ok: true, data: { drafts: [] } }) as DraftsResult);
    const store = new MailStore(fakeApi({ retrySentCopy, listMailDrafts }) as never);

    const error = await store.retrySentCopy('mara', 'op-7', 7);
    await flush();

    expect(retrySentCopy).toHaveBeenCalledWith('mara', 'op-7', 7);
    expect(error).toBeNull();
    expect(listMailDrafts).toHaveBeenCalled();
  });

  it('retrySentCopy resolves the error code on failure', async () => {
    const store = new MailStore(
      fakeApi({ retrySentCopy: async () => ({ ok: false, error: 'not_retryable' }) }) as never
    );

    expect(await store.retrySentCopy('mara', 'op-7', 7)).toBe('not_retryable');
  });
});

describe('wireMailEvents', () => {
  it('attaches the four handlers once and stays idempotent on repeat calls', () => {
    const on = vi.fn();
    const channel = { on } as unknown as Channel;

    wireMailEvents(channel);
    wireMailEvents(channel);

    expect(on).toHaveBeenCalledTimes(4);
    expect(on.mock.calls.map((c) => c[0])).toEqual([
      'mail_status',
      'mail_sync',
      'mail_message',
      'mail_draft'
    ]);
  });

  it('exports the singleton store', () => {
    expect(mailStore).toBeInstanceOf(MailStore);
  });
});
