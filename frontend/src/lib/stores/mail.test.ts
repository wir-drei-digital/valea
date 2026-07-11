import { describe, it, expect, vi } from 'vitest';
import { MailStore, resupplyCredential, type MailStatus } from './mail.svelte';
import type { ApiResult } from '../api/client';
import type { MailStatusPush } from '../socket';

type StatusResult = ApiResult<{ status: Record<string, any> }>;
type MessagesResult = ApiResult<{ messages: any[] }>;
type InboxResult = ApiResult<{ entries: any[] }>;
type DetailResult = ApiResult<{ message: Record<string, any>; inbox: boolean }>;
type SyncResult = ApiResult<{ started: boolean }>;
type CredentialResult = ApiResult<{ accepted: boolean }>;

const rawStatus: MailStatusPush = {
  configured: true,
  credential: 'present',
  state: 'idle',
  last_sync_at: '2026-07-10T12:00:00Z',
  last_error: null,
  account: 'mara@example.com',
  workspace_id: 'ws-1'
};

function fakeApi(overrides: {
  mailStatus?: () => Promise<StatusResult>;
  listMailMessages?: () => Promise<MessagesResult>;
  mailInbox?: () => Promise<InboxResult>;
  getMailMessage?: (msgId: string) => Promise<DetailResult>;
  mailSyncNow?: (generation: number) => Promise<SyncResult>;
  setMailCredential?: (secret: string, generation: number) => Promise<CredentialResult>;
}) {
  return {
    mailStatus: overrides.mailStatus ?? (async () => ({ ok: true, data: { status: rawStatus } }) as StatusResult),
    listMailMessages:
      overrides.listMailMessages ?? (async () => ({ ok: true, data: { messages: [] } }) as MessagesResult),
    mailInbox: overrides.mailInbox ?? (async () => ({ ok: true, data: { entries: [] } }) as InboxResult),
    getMailMessage:
      overrides.getMailMessage ??
      (async () => ({ ok: true, data: { message: {}, inbox: false } }) as DetailResult),
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
      account: 'mara@example.com',
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
  it('populates messages from mocked api', async () => {
    const messages = [{ msgId: 'm1', fromName: 'Priya', subject: 'Hi', hasAttachments: false }];
    const store = new MailStore(
      fakeApi({ listMailMessages: async () => ({ ok: true, data: { messages } }) }) as never
    );

    await store.refreshMessages();

    expect(store.messages).toEqual(messages);
  });

  it('leaves messages untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ listMailMessages: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshMessages();

    expect(store.messages).toEqual([]);
  });
});

describe('MailStore.refreshInbox', () => {
  it('populates inbox from mocked api', async () => {
    const entries = [{ uid: 1, fromText: 'Priya <p@x.com>', subject: 'Hi', date: '2026-07-10' }];
    const store = new MailStore(fakeApi({ mailInbox: async () => ({ ok: true, data: { entries } }) }) as never);

    await store.refreshInbox();

    expect(store.inbox).toEqual(entries);
  });

  it('leaves inbox untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ mailInbox: async () => ({ ok: false, error: 'workspace_not_open' }) }) as never
    );

    await store.refreshInbox();

    expect(store.inbox).toEqual([]);
  });
});

describe('MailStore.select', () => {
  it('loads detail on success', async () => {
    const message = { frontmatter: { subject: 'Hi' }, body: 'Body text', path: 'sources/mail/messages/m1.md' };
    const store = new MailStore(
      fakeApi({ getMailMessage: async () => ({ ok: true, data: { message, inbox: false } }) }) as never
    );

    await store.select('m1');

    expect(store.selected).toEqual({
      frontmatter: { subject: 'Hi' },
      body: 'Body text',
      path: 'sources/mail/messages/m1.md',
      inbox: false
    });
    expect(store.loading).toBe(false);
  });

  it('leaves selected untouched on failure', async () => {
    const store = new MailStore(
      fakeApi({ getMailMessage: async () => ({ ok: false, error: 'not_found' }) }) as never
    );

    await store.select('missing');

    expect(store.selected).toBeNull();
    expect(store.loading).toBe(false);
  });

  it('flips loading true while the fetch is in flight', async () => {
    let resolveFetch: (v: DetailResult) => void;
    const pending = new Promise<DetailResult>((resolve) => {
      resolveFetch = resolve;
    });
    const store = new MailStore(fakeApi({ getMailMessage: () => pending }) as never);

    const selectPromise = store.select('m1');
    expect(store.loading).toBe(true);

    resolveFetch!({ ok: true, data: { message: { body: 'x', path: 'p', frontmatter: null }, inbox: false } });
    await selectPromise;

    expect(store.loading).toBe(false);
  });
});

describe('MailStore.syncNow', () => {
  it('returns null on success', async () => {
    const store = new MailStore(fakeApi({}) as never);

    const result = await store.syncNow(3);

    expect(result).toBeNull();
  });

  it('surfaces the error code on failure', async () => {
    const store = new MailStore(
      fakeApi({ mailSyncNow: async () => ({ ok: false, error: 'not_configured' }) }) as never
    );

    const result = await store.syncNow(3);

    expect(result).toBe('not_configured');
  });

  it('passes the given generation through to the api', async () => {
    const mailSyncNow = vi.fn(async () => ({ ok: true, data: { started: true } }) as SyncResult);
    const store = new MailStore(fakeApi({ mailSyncNow }) as never);

    await store.syncNow(7);

    expect(mailSyncNow).toHaveBeenCalledWith(7);
  });
});

describe('MailStore.handleMailMessage', () => {
  it('triggers refreshMessages', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const store = new MailStore(fakeApi({ listMailMessages }) as never);

    store.handleMailMessage({ path: 'sources/mail/messages/m2.md' });
    await Promise.resolve();

    expect(listMailMessages).toHaveBeenCalledTimes(1);
  });
});

describe('MailStore.handleMailSync', () => {
  it('refreshes the inbox when the sync pass finishes', async () => {
    const mailInbox = vi.fn(async () => ({ ok: true, data: { entries: [] } }) as InboxResult);
    const store = new MailStore(fakeApi({ mailInbox }) as never);

    store.handleMailSync({ phase: 'finished', newMessages: 2 });
    await Promise.resolve();

    expect(mailInbox).toHaveBeenCalledTimes(1);
  });

  it('does nothing on the started phase', async () => {
    const mailInbox = vi.fn(async () => ({ ok: true, data: { entries: [] } }) as InboxResult);
    const store = new MailStore(fakeApi({ mailInbox }) as never);

    store.handleMailSync({ phase: 'started', newMessages: 0 });
    await Promise.resolve();

    expect(mailInbox).not.toHaveBeenCalled();
  });
});

describe('MailStore.handleMailStatus', () => {
  it('normalizes and stores status, and refetches messages + inbox (T13 activation race)', async () => {
    const listMailMessages = vi.fn(async () => ({ ok: true, data: { messages: [] } }) as MessagesResult);
    const mailInbox = vi.fn(async () => ({ ok: true, data: { entries: [] } }) as InboxResult);
    const store = new MailStore(fakeApi({ listMailMessages, mailInbox }) as never);

    store.handleMailStatus(rawStatus);
    await Promise.resolve();

    expect(store.status?.state).toBe('idle');
    expect(listMailMessages).toHaveBeenCalledTimes(1);
    expect(mailInbox).toHaveBeenCalledTimes(1);
  });
});

describe('resupplyCredential', () => {
  const configuredMissing: MailStatus = {
    configured: true,
    credential: 'missing',
    state: 'idle',
    lastSyncAt: null,
    lastError: null,
    account: 'mara@example.com',
    workspaceId: 'ws-1'
  };

  it('no-ops outside the desktop app (no Tauri global in vitest)', async () => {
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);

    const result = await resupplyCredential(configuredMissing, { setMailCredential });

    expect(result).toBe(false);
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when the credential is already present', async () => {
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const present: MailStatus = { ...configuredMissing, credential: 'present' };

    const result = await resupplyCredential(present, { setMailCredential });

    expect(result).toBe(false);
    expect(setMailCredential).not.toHaveBeenCalled();
  });

  it('no-ops when not configured', async () => {
    const setMailCredential = vi.fn(async () => ({ ok: true, data: { accepted: true } }) as CredentialResult);
    const notConfigured: MailStatus = { ...configuredMissing, configured: false };

    const result = await resupplyCredential(notConfigured, { setMailCredential });

    expect(result).toBe(false);
    expect(setMailCredential).not.toHaveBeenCalled();
  });
});
