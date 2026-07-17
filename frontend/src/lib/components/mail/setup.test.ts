import { describe, it, expect, vi } from 'vitest';
import {
  submitMailSetup,
  mailSetupErrorMessage,
  normalizeMailDoctorChecks,
  foldersCheckFailed,
  createFoldersAndRecheck,
  createFoldersErrorMessage,
  type MailSetupDeps,
  type MailSetupFormInput,
  type CreateFoldersDeps
} from './mail-shapes';
import type { ApiResult } from '$lib/api/client';

// Test 17 (account setup + mail doctor UI): pure-logic coverage per the
// task brief — `submitMailSetup`'s desktop-vs-browser sequencing (mocking
// the `keychain.ts` seam's shape, not the module itself, since this is a
// plain function taking injected deps — no vi.mock needed here), the
// doctor-check normalizer, and the "Create folders" gating. Component
// rendering itself has no test harness (see `mail-components.test.ts`'s
// header comment) — `SetupPanel.svelte`/`MailDoctorPanel.svelte` just wire
// these functions to the real `api`/`keychain`/`mailStore`.

function ok<T>(data: T): ApiResult<T> {
  return { ok: true, data };
}

function fail<T>(error: string): ApiResult<T> {
  return { ok: false, error };
}

const input: MailSetupFormInput = {
  account: 'work-inbox',
  host: 'imap.example.com',
  port: 993,
  username: 'mara@example.com',
  secret: 'hunter2',
  generation: 3
};

function makeDeps(overrides: Partial<MailSetupDeps> = {}): MailSetupDeps {
  return {
    api: {
      setupMailAccount: vi.fn(async () => ok({ saved: true })),
      setMailCredential: vi.fn(async () => ok({ accepted: true }))
    },
    inDesktop: vi.fn(() => false),
    refreshWorkspaceId: vi.fn(async () => 'ws-1'),
    keychainSet: vi.fn(async () => true),
    ...overrides
  };
}

describe('submitMailSetup — browser (dev) path', () => {
  it('calls setupMailAccount then setMailCredential directly, never touching the keychain', async () => {
    const deps = makeDeps();

    const outcome = await submitMailSetup(input, deps);

    // `account` IS the slug — a real form field validated client-side
    // against `MAIL_SLUG_RE`; the backend re-validates on its side.
    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      'work-inbox',
      'imap.example.com',
      993,
      'mara@example.com',
      3
    );
    expect(deps.refreshWorkspaceId).not.toHaveBeenCalled();
    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(outcome).toEqual({ ok: true, devMode: true });
  });

  it('rejects an invalid slug before any RPC call', async () => {
    const deps = makeDeps();

    const outcome = await submitMailSetup({ ...input, account: 'Not A Slug' }, deps);

    expect(outcome).toEqual({ ok: false, error: 'invalid_slug' });
    expect(deps.api.setupMailAccount).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
  });
});

describe('submitMailSetup — desktop path', () => {
  it('refreshes the workspace id and stashes the secret in the keychain before handing it to setMailCredential, in order', async () => {
    const order: string[] = [];
    const deps = makeDeps({
      inDesktop: vi.fn(() => true),
      refreshWorkspaceId: vi.fn(async () => {
        order.push('refreshWorkspaceId');
        return 'ws-fresh';
      }),
      keychainSet: vi.fn(async (...args) => {
        order.push('keychainSet');
        return true;
      }),
      api: {
        setupMailAccount: vi.fn(async () => {
          order.push('setupMailAccount');
          return ok({ saved: true });
        }),
        setMailCredential: vi.fn(async () => {
          order.push('setMailCredential');
          return ok({ accepted: true });
        })
      }
    });

    const outcome = await submitMailSetup(input, deps);

    expect(order).toEqual(['setupMailAccount', 'refreshWorkspaceId', 'keychainSet', 'setMailCredential']);
    expect(deps.keychainSet).toHaveBeenCalledWith('ws-fresh', 'work-inbox:imap', 'hunter2');
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  it('keys the keychain entry on <slug>:imap, never on the IMAP username', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    await submitMailSetup({ ...input, username: 'form-typed@example.com' }, deps);

    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:imap', 'hunter2');
  });

  it('still hands the secret to setMailCredential even when refreshWorkspaceId comes back empty (best-effort keychain)', async () => {
    const deps = makeDeps({
      inDesktop: vi.fn(() => true),
      refreshWorkspaceId: vi.fn(async () => null)
    });

    const outcome = await submitMailSetup(input, deps);

    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  it('still hands the secret to setMailCredential even when keychainSet itself resolves false', async () => {
    const deps = makeDeps({
      inDesktop: vi.fn(() => true),
      keychainSet: vi.fn(async () => false)
    });

    const outcome = await submitMailSetup(input, deps);

    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(outcome).toEqual({ ok: true, devMode: false });
  });
});

describe('submitMailSetup — failure short-circuiting', () => {
  it('a setupMailAccount failure never calls the keychain or setMailCredential', async () => {
    const deps = makeDeps({
      inDesktop: vi.fn(() => true),
      api: {
        setupMailAccount: vi.fn(async () => fail('workspace_changed')),
        setMailCredential: vi.fn(async () => ok({ accepted: true }))
      }
    });

    const outcome = await submitMailSetup(input, deps);

    expect(deps.refreshWorkspaceId).not.toHaveBeenCalled();
    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
    expect(outcome).toEqual({ ok: false, error: 'workspace_changed' });
  });

  it('a setMailCredential failure surfaces its error even though setupMailAccount succeeded', async () => {
    const deps = makeDeps({
      api: {
        setupMailAccount: vi.fn(async () => ok({ saved: true })),
        setMailCredential: vi.fn(async () => fail('workspace_not_open'))
      }
    });

    const outcome = await submitMailSetup(input, deps);

    expect(outcome).toEqual({ ok: false, error: 'workspace_not_open' });
  });
});

describe('mailSetupErrorMessage', () => {
  it.each([
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['invalid_slug', 'Account id must be lowercase letters, digits, and dashes (up to 32 characters).'],
    ['identity_mismatch', 'A different account already owns this folder on disk. Purge it first from the account list.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(mailSetupErrorMessage(code)).toBe(expected);
  });

  it('falls back to a generic sentence for anything unrecognized', () => {
    expect(mailSetupErrorMessage('unknown_error')).toBe(
      'Could not save your mail account. Check the details and try again.'
    );
  });
});

describe('normalizeMailDoctorChecks', () => {
  it('passes through a full set of ok/failed/unknown checks unchanged', () => {
    const raw = [
      { id: 'config_present', label: 'Mail account configured', status: 'ok', detail: 'Configured.', remedy: null },
      {
        id: 'tcp_reachable',
        label: 'Server reachable',
        status: 'failed',
        detail: 'Could not connect.',
        remedy: 'Check the host and port.'
      },
      { id: 'login_ok', label: 'Login', status: 'unknown', detail: 'not checked.', remedy: null }
    ];

    expect(normalizeMailDoctorChecks(raw)).toEqual([
      { id: 'config_present', label: 'Mail account configured', status: 'ok', detail: 'Configured.', remedy: null },
      {
        id: 'tcp_reachable',
        label: 'Server reachable',
        status: 'failed',
        detail: 'Could not connect.',
        remedy: 'Check the host and port.'
      },
      { id: 'login_ok', label: 'Login', status: 'unknown', detail: 'not checked.', remedy: null }
    ]);
  });

  it('drops entries with a missing/non-string id', () => {
    const raw = [{ label: 'no id', status: 'ok', detail: '', remedy: null }, null, 'x', 42];

    expect(normalizeMailDoctorChecks(raw)).toEqual([]);
  });

  it('defaults label to id, status to "unknown", detail to "", remedy to null for malformed fields', () => {
    const raw = [{ id: 'folders' }];

    expect(normalizeMailDoctorChecks(raw)).toEqual([
      { id: 'folders', label: 'folders', status: 'unknown', detail: '', remedy: null }
    ]);
  });

  it('returns [] for a non-array value', () => {
    expect(normalizeMailDoctorChecks(undefined)).toEqual([]);
    expect(normalizeMailDoctorChecks(null)).toEqual([]);
    expect(normalizeMailDoctorChecks('nope')).toEqual([]);
  });
});

describe('createFoldersAndRecheck', () => {
  function makeFolderDeps(overrides: Partial<CreateFoldersDeps> = {}): CreateFoldersDeps {
    return {
      api: { createMailFolders: vi.fn(async () => ok({ created: ['Archive'] })) },
      rerunDoctor: vi.fn(async () => {}),
      setBusy: vi.fn(),
      ...overrides
    };
  }

  it('success path: busy on -> createMailFolders -> re-run doctor -> busy off, resolving null', async () => {
    const order: string[] = [];
    const deps = makeFolderDeps({
      api: {
        createMailFolders: vi.fn(async () => {
          order.push('createMailFolders');
          return ok({ created: ['Archive'] });
        })
      },
      rerunDoctor: vi.fn(async () => {
        order.push('rerunDoctor');
      }),
      setBusy: vi.fn((busy: boolean) => {
        order.push(`setBusy(${busy})`);
      })
    });

    const message = await createFoldersAndRecheck(deps, 'work-inbox', 3);

    expect(order).toEqual(['setBusy(true)', 'createMailFolders', 'rerunDoctor', 'setBusy(false)']);
    expect(deps.api.createMailFolders).toHaveBeenCalledWith('work-inbox', 3);
    expect(message).toBeNull();
  });

  it('error path: a createMailFolders failure surfaces a message, skips the doctor re-run, and still resets busy', async () => {
    const deps = makeFolderDeps({
      api: { createMailFolders: vi.fn(async () => fail('workspace_changed')) }
    });

    const message = await createFoldersAndRecheck(deps, 'work-inbox', 3);

    expect(message).toBe('Your workspace changed. Reopen it and try again.');
    expect(deps.rerunDoctor).not.toHaveBeenCalled();
    expect(deps.setBusy).toHaveBeenLastCalledWith(false);
  });

  it('still resets busy even when a step throws (the throw propagates)', async () => {
    const deps = makeFolderDeps({
      rerunDoctor: vi.fn(async () => {
        throw new Error('boom');
      })
    });

    await expect(createFoldersAndRecheck(deps, 'work-inbox', 3)).rejects.toThrow('boom');
    expect(deps.setBusy).toHaveBeenLastCalledWith(false);
  });
});

describe('createFoldersErrorMessage', () => {
  it.each([
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['not_configured', 'Connect your mailbox first.'],
    ['no_credential', 'Enter your mailbox password first.'],
    ['inactive', 'No workspace is open.'],
    ['anything_else', 'Could not create the folders. Check the connection and try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(createFoldersErrorMessage(code)).toBe(expected);
  });
});

describe('foldersCheckFailed', () => {
  it('is true when the folders check failed', () => {
    const checks = normalizeMailDoctorChecks([
      { id: 'login_ok', label: 'Login', status: 'ok', detail: '', remedy: null },
      { id: 'folders', label: 'Folders', status: 'failed', detail: 'Missing folder(s).', remedy: 'Create them.' }
    ]);

    expect(foldersCheckFailed(checks)).toBe(true);
  });

  it('is false when the folders check is ok', () => {
    const checks = normalizeMailDoctorChecks([{ id: 'folders', label: 'Folders', status: 'ok', detail: '', remedy: null }]);

    expect(foldersCheckFailed(checks)).toBe(false);
  });

  it('is false when the folders check is unknown (gated by an earlier failure)', () => {
    const checks = normalizeMailDoctorChecks([
      { id: 'folders', label: 'Folders', status: 'unknown', detail: 'not checked.', remedy: null }
    ]);

    expect(foldersCheckFailed(checks)).toBe(false);
  });

  it('is false when there is no folders check at all, or the list is empty', () => {
    expect(foldersCheckFailed(normalizeMailDoctorChecks([{ id: 'login_ok', label: 'Login', status: 'failed', detail: '', remedy: 'x' }]))).toBe(
      false
    );
    expect(foldersCheckFailed([])).toBe(false);
  });
});
