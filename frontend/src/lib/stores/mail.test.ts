import { describe, it, expect, vi, beforeEach } from 'vitest';
import {
  MailStore,
  mailStore,
  normalizeMailAccountStatus,
  normalizeMailDraft,
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
type PushResult = ApiResult<{ state: string }>;

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
  getMailMessage?: (account: string, msgId: string) => Promise<DetailResult>;
  mailSyncNow?: (account: string, generation: number) => Promise<SyncResult>;
  setMailCredential?: (account: string, secret: string, generation: number) => Promise<CredentialResult>;
  applyMailOps?: (account: string, ops: Record<string, unknown>[], generation: number) => Promise<OpsResult>;
  listMailDrafts?: () => Promise<DraftsResult>;
  getMailDraft?: (account: string, draftName: string) => Promise<DraftContentResult>;
  pushDraftToMailbox?: (
    account: string,
    draftName: string,
    contentHash: string,
    generation: number
  ) => Promise<PushResult>;
}) {
  return {
    mailStatus:
      overrides.mailStatus ?? (async () => ({ ok: true, data: { accounts: [rawMara, rawZoe] } }) as StatusResult),
    listMailFolders:
      overrides.listMailFolders ?? (async () => ({ ok: true, data: { folders: [] } }) as FoldersResult),
    listMailMessages:
      overrides.listMailMessages ?? (async () => ({ ok: true, data: { messages: [] } }) as MessagesResult),
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
    pushDraftToMailbox:
      overrides.pushDraftToMailbox ?? (async () => ({ ok: true, data: { state: 'pushing' } }) as PushResult)
  };
}

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
      folders: null
    } satisfies MailAccountStatus);
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
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX');
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
    store.selected = { frontmatter: null, body: 'x', path: 'p' };
    listMailFolders.mockClear();
    listMailMessages.mockClear();

    await store.selectAccount('zoe');

    expect(store.selectedAccount).toBe('zoe');
    expect(store.selectedFolder).toBe('INBOX');
    expect(store.selected).toBeNull();
    expect(listMailFolders).toHaveBeenCalledWith('zoe');
    expect(listMailMessages).toHaveBeenCalledWith('zoe', 'INBOX');
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

    await store.selectFolder('AI/Review');

    expect(store.selectedFolder).toBe('AI/Review');
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'AI/Review');
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
      path: 'sources/mail/mara/views/messages/m1.md'
    });
    expect(store.loading).toBe(false);
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
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX');
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
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX');
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
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX');
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
    expect(listMailMessages).toHaveBeenCalledWith('mara', 'INBOX');
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
      recipients: {
        to: [{ name: null, email: 'alex@example.com' }],
        cc: [],
        bcc: [],
        subject: 'Re: Kickoff'
      }
    });
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
        pushDraftToMailbox: async () => ({ ok: false, error: 'hash_mismatch' }),
        listMailDrafts
      }) as never
    );

    const outcome = await store.pushDraft('mara', 'reply.md', 7);
    await flush();

    expect(outcome).toEqual({ error: 'hash_mismatch' });
    expect(listMailDrafts).toHaveBeenCalled();
  });
});

describe('wireMailEvents', () => {
  it('attaches the three handlers once and stays idempotent on repeat calls', () => {
    const on = vi.fn();
    const channel = { on } as unknown as Channel;

    wireMailEvents(channel);
    wireMailEvents(channel);

    expect(on).toHaveBeenCalledTimes(3);
    expect(on.mock.calls.map((c) => c[0])).toEqual(['mail_status', 'mail_sync', 'mail_message']);
  });

  it('exports the singleton store', () => {
    expect(mailStore).toBeInstanceOf(MailStore);
  });
});
