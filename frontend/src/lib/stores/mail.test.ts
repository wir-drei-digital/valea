import { describe, it, expect, vi, beforeEach } from 'vitest';
import { MailStore, mailStore, resupplyCredential, wireMailEvents, type MailStatus } from './mail.svelte';
import { inDesktop, keychainGet } from '../keychain';
import { workspaceStore } from './workspace.svelte';
import type { ApiResult } from '../api/client';
import type { MailStatusPush } from '../socket';
import type { Channel } from 'phoenix';

// The keychain seam is mocked at the module boundary (mirrors
// keychain.test.ts mocking `@tauri-apps/api/core`) so `resupplyCredential`'s
// desktop path — including WHICH key the secret is looked up under — is
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

type StatusResult = ApiResult<{ status: Record<string, any> }>;
type MessagesResult = ApiResult<{ messages: any[] }>;
type DetailResult = ApiResult<{ message: Record<string, any> }>;
type SyncResult = ApiResult<{ started: boolean }>;
type CredentialResult = ApiResult<{ accepted: boolean }>;

// account (display label) deliberately differs from username (the IMAP
// login) throughout these fixtures — the keychain lookup keys on the
// USERNAME (spec §Credentials: account = workspace_id:username), and a
// fixture where the two coincide couldn't catch a mixup between them.
// `account` here is the real v4 slug (Task 10) — the RPC layer's
// `mailStatus` wrapper (`api/client.ts`) already picked the primary account
// out of the backend's `accounts: [...]` list before this shape reaches the
// store, so `MailStore` itself still only ever sees one.
const rawStatus: MailStatusPush = {
  configured: true,
  credential: 'present',
  state: 'idle',
  last_sync_at: '2026-07-10T12:00:00Z',
  last_error: null,
  account: 'maras-mail',
  username: 'mara@example.com',
  workspace_id: 'ws-1'
};

function fakeApi(overrides: {
  mailStatus?: () => Promise<StatusResult>;
  listMailMessages?: (account: string, folder: string) => Promise<MessagesResult>;
  getMailMessage?: (account: string, msgId: string) => Promise<DetailResult>;
  mailSyncNow?: (account: string, generation: number) => Promise<SyncResult>;
  setMailCredential?: (account: string, secret: string, generation: number) => Promise<CredentialResult>;
}) {
  return {
    mailStatus: overrides.mailStatus ?? (async () => ({ ok: true, data: { status: rawStatus } }) as StatusResult),
    listMailMessages:
      overrides.listMailMessages ?? (async () => ({ ok: true, data: { messages: [] } }) as MessagesResult),
    getMailMessage:
      overrides.getMailMessage ?? (async () => ({ ok: true, data: { message: {} } }) as DetailResult),
    mailSyncNow: overrides.mailSyncNow ?? (async () => ({ ok: true, data: { started: true } }) as SyncResult),
    setMailCredential:
      overrides.setMailCredential ?? (async () => ({ ok: true, data: { accepted: true } }) as CredentialResult)
  };
}

describe('MailStore.refreshStatus', () => {
  it('normalizes the raw wire payload (snake_case) into MailStatus (camelCase)', async () => {
    const store = new MailStore(fakeApi({}) as never);

    await store.refreshStatus();

    expect(store.status).toEqual({
      configured: true,
      credential: 'present',
      state: 'idle',
      lastSyncAt: '2026-07-10T12:00:00Z',
      lastError: null,
      account: 'maras-mail',
      username: 'mara@example.com',
      workspaceId: 'ws-1'
    });
  });

  it('leaves status untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ mailStatus: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshStatus();

    expect(store.status).toBeNull();
  });
});

describe('MailStore.refreshMessages', () => {
  it('populates messages from mocked api, reading the AI/Review folder', async () => {
    const messages = [{ msgId: 'm1', fromName: 'Priya', subject: 'Hi', hasAttachments: false }];
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    await store.refreshMessages('maras-mail');

    expect(store.messages).toEqual(messages);
    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'AI/Review');
  });

  it('leaves messages untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ listMailMessages: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshMessages('maras-mail');

    expect(store.messages).toEqual([]);
  });

  it('clears messages (a no-op fetch) when no account is known yet', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    await store.refreshMessages();

    expect(store.messages).toEqual([]);
    expect(listMailMessages).not.toHaveBeenCalled();
  });

  it('defaults to the current status.account when none is passed', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    await store.refreshStatus();
    await store.refreshMessages();

    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'AI/Review');
  });
});

describe('MailStore.refreshInbox', () => {
  it('populates inbox from mocked api, reading the INBOX folder', async () => {
    const messages = [{ msgId: 'm2', fromName: 'Priya', subject: 'Hi', date: '2026-07-10' }];
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    await store.refreshInbox('maras-mail');

    expect(store.inbox).toEqual(messages);
    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'INBOX');
  });

  it('leaves inbox untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ listMailMessages: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshInbox('maras-mail');

    expect(store.inbox).toEqual([]);
  });
});

describe('MailStore.select', () => {
  it('loads detail on success', async () => {
    const message = { frontmatter: { subject: 'Hi' }, body: 'Body text', path: 'sources/mail/messages/m1.md' };
    const store = new MailStore(
      fakeApi({ getMailMessage: async () => ({ ok: true, data: { message } }) }) as never
    );

    await store.select('maras-mail', 'm1');

    expect(store.selected).toEqual({
      frontmatter: { subject: 'Hi' },
      body: 'Body text',
      path: 'sources/mail/messages/m1.md'
    });
    expect(store.loading).toBe(false);
  });

  it('leaves selected untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ getMailMessage: async () => ({ ok: false, error: 'not_found' }) }) as never
    );

    await store.select('maras-mail', 'missing');

    expect(store.selected).toBeNull();
    expect(store.loading).toBe(false);
  });

  it('flips loading true while the fetch is in flight', async () => {
    let resolveFetch: (v: DetailResult) => void;
    const pending = new Promise<DetailResult>((resolve) => {
      resolveFetch = resolve;
    });
    const store = new MailStore(fakeApi({ getMailMessage: () => pending }) as never);

    const selectPromise = store.select('maras-mail', 'm1');
    expect(store.loading).toBe(true);

    resolveFetch!({ ok: true, data: { message: { body: 'x', path: 'p', frontmatter: null } } });
    await selectPromise;

    expect(store.loading).toBe(false);
  });
});

describe('MailStore.syncNow', () => {
  it('returns null on success', async () => {
    const store = new MailStore(fakeApi({}) as never);

    const result = await store.syncNow('maras-mail', 3);

    expect(result).toBeNull();
  });

  it('surfaces the error code on failure', async () => {
    const store = new MailStore(
      fakeApi({ mailSyncNow: async () => ({ ok: false, error: 'not_configured' }) }) as never
    );

    const result = await store.syncNow('maras-mail', 3);

    expect(result).toBe('not_configured');
  });

  it('passes the given account + generation through to the api', async () => {
    const mailSyncNow = vi.fn(async () => ({ ok: true, data: { started: true } }) as SyncResult);
    const store = new MailStore(fakeApi({ mailSyncNow }) as never);

    await store.syncNow('maras-mail', 7);

    expect(mailSyncNow).toHaveBeenCalledWith('maras-mail', 7);
  });
});

describe('MailStore.handleMailMessage', () => {
  it('triggers refreshMessages', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    store.handleMailMessage({ path: 'sources/mail/messages/m2.md' });
    await Promise.resolve();

    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'AI/Review');
  });
});

describe('MailStore.handleMailSync', () => {
  it('refreshes the inbox when the sync pass finishes', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);
    await store.refreshStatus();

    store.handleMailSync({ phase: 'finished', newMessages: 2 });
    await Promise.resolve();

    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'INBOX');
  });

  it('does nothing on the started phase', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    store.handleMailSync({ phase: 'started', newMessages: 0 });
    await Promise.resolve();

    expect(listMailMessages).not.toHaveBeenCalled();
  });
});

describe('MailStore.handleMailStatus', () => {
  it('normalizes and stores status, and refetches messages + inbox (T13 activation race)', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    store.handleMailStatus(rawStatus);
    await Promise.resolve();

    expect(store.status?.state).toBe('idle');
    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'AI/Review');
    expect(listMailMessages).toHaveBeenCalledWith('maras-mail', 'INBOX');
  });
});

describe('MailStore.onMailStatus', () => {
  it('notifies subscribers of every mail_status push, alongside the store refetches (Today unfreezes its cockpit snapshot on this)', () => {
    const store = new MailStore(fakeApi({}) as never);
    const listener = vi.fn();

    store.onMailStatus(listener);
    store.handleMailStatus(rawStatus);

    expect(listener).toHaveBeenCalledWith(rawStatus);
  });

  it('stops notifying once unsubscribed', () => {
    const store = new MailStore(fakeApi({}) as never);
    const listener = vi.fn();

    const unsubscribe = store.onMailStatus(listener);
    unsubscribe();
    store.handleMailStatus(rawStatus);

    expect(listener).not.toHaveBeenCalled();
  });
});

describe('resupplyCredential', () => {
  const configuredMissing: MailStatus = {
    configured: true,
    credential: 'missing',
    state: 'idle',
    lastSyncAt: null,
    lastError: null,
    account: 'maras-mail',
    username: 'mara@example.com',
    workspaceId: 'ws-1'
  };

  it('no-ops outside the desktop app', async () => {
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const result = await resupplyCredential(configuredMissing, { setMailCredential });

    expect(result).toBe(false);
    expect(keychainGet).not.toHaveBeenCalled();
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when the credential is already present', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const present: MailStatus = { ...configuredMissing, credential: 'present' };

    const result = await resupplyCredential(present, { setMailCredential });

    expect(result).toBe(false);
    expect(keychainGet).not.toHaveBeenCalled();
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when not configured', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const notConfigured: MailStatus = { ...configuredMissing, configured: false };

    const result = await resupplyCredential(notConfigured, { setMailCredential });

    expect(result).toBe(false);
    expect(keychainGet).not.toHaveBeenCalled();
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when the status carries no username to key the lookup on', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const noUsername: MailStatus = { ...configuredMissing, username: null };

    const result = await resupplyCredential(noUsername, { setMailCredential });

    expect(result).toBe(false);
    expect(keychainGet).not.toHaveBeenCalled();
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when the status carries no account to target the credential at', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const noAccount: MailStatus = { ...configuredMissing, account: null };

    const result = await resupplyCredential(noAccount, { setMailCredential });

    expect(result).toBe(false);
    expect(keychainGet).not.toHaveBeenCalled();
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('desktop happy path: looks the secret up under the USERNAME (not the account label) and re-supplies it', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockResolvedValue('hunter2');
    workspaceStore.generation = 5;
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const result = await resupplyCredential(configuredMissing, { setMailCredential });

    // The lookup key is the IMAP login, NOT the display label — the setup
    // flow stores the secret under workspace_id:username (spec §Credentials),
    // so keying on `account` ("maras-mail") would silently find nothing
    // whenever label and login differ.
    expect(keychainGet).toHaveBeenCalledWith('ws-1', 'mara@example.com');
    expect(setMailCredential).toHaveBeenCalledWith('maras-mail', 'hunter2', 5);
    expect(result).toBe(true);
  });

  it('no-ops (without calling the RPC) when the keychain has nothing stored', async () => {
    vi.mocked(inDesktop).mockReturnValue(true);
    vi.mocked(keychainGet).mockResolvedValue(null);
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const result = await resupplyCredential(configuredMissing, { setMailCredential });

    expect(result).toBe(false);
    expect(setMailCredential).not.toHaveBeenCalled();
  });
});

// `mailEventsWired` is a module-level latch (see `wireMailEvents` in
// `mail.svelte.ts`), so — same caveat every other `wire*Events` latch test
// in this codebase has — it can only be meaningfully exercised ONCE per test
// file. This is the single test in the file that calls `wireMailEvents`,
// keeping the "first call wins" assertion deterministic instead of
// depending on test execution order.
describe('wireMailEvents', () => {
  it('attaches all three mail handlers to the first channel only, each driving the singleton mailStore', () => {
    const handleMailStatus = vi.spyOn(mailStore, 'handleMailStatus').mockImplementation(() => {});
    const handleMailSync = vi.spyOn(mailStore, 'handleMailSync').mockImplementation(() => {});
    const handleMailMessage = vi.spyOn(mailStore, 'handleMailMessage').mockImplementation(() => {});

    const handlersA: Record<string, (payload: unknown) => void> = {};
    const channelA = { on: (event: string, cb: (payload: unknown) => void) => (handlersA[event] = cb) } as unknown as Channel;
    const handlersB: Record<string, (payload: unknown) => void> = {};
    const channelB = { on: (event: string, cb: (payload: unknown) => void) => (handlersB[event] = cb) } as unknown as Channel;

    wireMailEvents(channelA);
    wireMailEvents(channelB); // idempotent no-op: never attaches to a second channel

    expect(handlersA['mail_status']).toBeTypeOf('function');
    expect(handlersA['mail_sync']).toBeTypeOf('function');
    expect(handlersA['mail_message']).toBeTypeOf('function');
    expect(handlersB['mail_status']).toBeUndefined();

    handlersA['mail_status']({ configured: true });
    handlersA['mail_sync']({ phase: 'finished' });
    handlersA['mail_message']({ path: 'x' });

    expect(handleMailStatus).toHaveBeenCalledWith({ configured: true });
    expect(handleMailSync).toHaveBeenCalledWith({ phase: 'finished' });
    expect(handleMailMessage).toHaveBeenCalledWith({ path: 'x' });

    handleMailStatus.mockRestore();
    handleMailSync.mockRestore();
    handleMailMessage.mockRestore();
  });
});
