import { describe, it, expect, vi } from 'vitest';
import {
  submitMailSetup,
  mailSetupErrorMessage,
  smtpFormError,
  normalizeMailDoctorChecks,
  foldersCheckFailed,
  createFoldersAndRecheck,
  createFoldersErrorMessage,
  mailAuthMode,
  mailOauthProvider,
  mailOauthProviderLabel,
  mailOauthSignInLabel,
  mailSignInErrorMessage,
  needsMailSignIn,
  startMailSignIn,
  accountRecovery,
  isCorruptAccountMeta,
  mailKeychainWorkspaceId,
  removeMailAccountAndForget,
  CORRUPT_ACCOUNT_META_ERROR,
  type MailRemovalDeps,
  type MailSetupDeps,
  type MailSetupFormInput,
  type MailSetupSmtpInput,
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
    // The sixth argument is the optional v5 SMTP block — `null` for a
    // push-only account, which is the v4 behaviour verbatim. The seventh is
    // the notifications opt-in, `false` unless the form says otherwise (the
    // action re-renders the account entry, so "not stated" IS "off"), and the
    // eighth is the SASL mode, and the ninth the public OAuth2 client-id
    // override — both on the same rule.
    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      'work-inbox',
      'imap.example.com',
      993,
      'mara@example.com',
      3,
      null,
      false,
      'password',
      null
    );
    expect(deps.refreshWorkspaceId).not.toHaveBeenCalled();
    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(outcome).toEqual({ ok: true, devMode: true });
  });

  it('forwards the notifications opt-in when the form turned it on', async () => {
    const deps = makeDeps();

    await submitMailSetup({ ...input, notifications: true }, deps);

    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      'work-inbox',
      'imap.example.com',
      993,
      'mara@example.com',
      3,
      null,
      true,
      'password',
      null
    );
  });

  it('rejects an invalid slug before any RPC call', async () => {
    const deps = makeDeps();

    const outcome = await submitMailSetup({ ...input, account: 'Not A Slug' }, deps);

    expect(outcome).toEqual({ ok: false, error: 'invalid_slug' });
    expect(deps.api.setupMailAccount).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
  });
});

describe('submitMailSetup — edit mode (blank secrets keep stored credentials)', () => {
  it('a blank IMAP secret skips the keychain write and the credential hand-off entirely', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    const outcome = await submitMailSetup({ ...input, secret: '' }, deps);

    expect(deps.api.setupMailAccount).toHaveBeenCalledTimes(1);
    expect(deps.refreshWorkspaceId).not.toHaveBeenCalled();
    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  it('a typed SMTP secret still lands while the blank IMAP one is kept', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    const outcome = await submitMailSetup(
      {
        ...input,
        secret: '',
        smtp: {
          host: 'smtp.example.com',
          port: 587,
          security: 'starttls',
          username: 'mara@example.com',
          from: '',
          fromName: '',
          secret: 'smtp-only-secret',
          sameAsImap: false
        }
      },
      deps
    );

    expect(deps.keychainSet).toHaveBeenCalledTimes(1);
    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:smtp', 'smtp-only-secret');
    expect(deps.api.setMailCredential).toHaveBeenCalledTimes(1);
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'smtp-only-secret', 3, 'smtp');
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  it('"same as IMAP" with a blank IMAP secret keeps BOTH slots', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    await submitMailSetup(
      {
        ...input,
        secret: '',
        smtp: {
          host: 'smtp.example.com',
          port: 587,
          security: 'starttls',
          username: 'mara@example.com',
          from: '',
          fromName: '',
          secret: '',
          sameAsImap: true
        }
      },
      deps
    );

    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
  });
});

// The SASL mode (M6 task 15) is the one prefilled field with a SECURITY
// consequence if it fails to round-trip: `setup_mail_account` re-renders the
// account entry whole, so an edit that doesn't send `oauth2` back rewrites the
// account as a password account — and the engine then offers that account's
// OAuth2 access token as a LOGIN password / `AUTH PLAIN` secret. These pin both
// halves of the trip at the pure-.ts level (the component only assigns between
// them, which `bun run check` types).
describe('the auth mode round trip', () => {
  it('mailAuthMode narrows the RPC string, defaulting anything unrecognized to password', () => {
    expect(mailAuthMode('oauth2')).toBe('oauth2');
    expect(mailAuthMode('password')).toBe('password');
    expect(mailAuthMode(null)).toBe('password');
    expect(mailAuthMode(undefined)).toBe('password');
    expect(mailAuthMode('OAUTH2')).toBe('password');
  });

  it('an edit of an oauth2 account sends its mode BACK, never downgrading it', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    // Exactly the shape `get_mail_account_settings` returns for the edit form's
    // prefill — the mode included, which is why `getMailAccountSettingsFields`
    // has to select it.
    const stored = { account: { host: 'imap.example.com', port: 993, username: 'mara@example.com', auth: 'oauth2' } };

    // ...and exactly the save that used to lose it: only a sibling field
    // changed, both secrets left blank ("keep the stored ones").
    const outcome = await submitMailSetup(
      { ...input, secret: '', notifications: true, auth: mailAuthMode(stored.account.auth) },
      deps
    );

    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      'work-inbox',
      'imap.example.com',
      993,
      'mara@example.com',
      3,
      null,
      true,
      'oauth2',
      null
    );
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  it('a form that states no mode saves password — the backend default, unchanged', async () => {
    const deps = makeDeps();

    await submitMailSetup(input, deps);

    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      expect.anything(),
      expect.anything(),
      expect.anything(),
      null,
      false,
      'password',
      null
    );
  });

  it('an edit of an account with a client-id override sends it BACK, never dropping it', async () => {
    // The same whole-entry hazard `auth` has, one field over: this action
    // re-renders the account entry, so an omitted override is a DROPPED
    // override — and an account authorizing under a different client id than
    // it was registered with gets `invalid_grant`, i.e. dies silently.
    const deps = makeDeps();

    await submitMailSetup(
      { ...input, secret: '', auth: 'oauth2', oauthClientId: '123-abc.apps.googleusercontent.com' },
      deps
    );

    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      expect.anything(),
      expect.anything(),
      expect.anything(),
      expect.anything(),
      expect.anything(),
      null,
      false,
      'oauth2',
      '123-abc.apps.googleusercontent.com'
    );
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

// -- SMTP (spec G §Configuration & credentials) --------------------------------

describe('submitMailSetup — with an SMTP block', () => {
  const smtp: MailSetupSmtpInput = {
    host: 'smtp.example.com',
    port: 587,
    security: 'starttls',
    username: 'mara@example.com',
    from: '',
    fromName: 'Mara Vance',
    secret: 'smtp-only-secret',
    sameAsImap: false
  };

  it('passes the SMTP block to setupMailAccount and keys its secret on <slug>:smtp with kind smtp', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    const outcome = await submitMailSetup({ ...input, smtp }, deps);

    expect(deps.api.setupMailAccount).toHaveBeenCalledWith(
      'work-inbox',
      'imap.example.com',
      993,
      'mara@example.com',
      3,
      {
        host: 'smtp.example.com',
        port: 587,
        security: 'starttls',
        username: 'mara@example.com',
        from: null,
        fromName: 'Mara Vance'
      },
      false,
      'password',
      null
    );
    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:imap', 'hunter2');
    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:smtp', 'smtp-only-secret');
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'smtp-only-secret', 3, 'smtp');
    expect(outcome).toEqual({ ok: true, devMode: false });
  });

  // "Same as IMAP" COPIES the IMAP secret into the smtp entry (spec G: a
  // copy, not an alias — rotation stays independent).
  it('"same as IMAP" copies the IMAP secret into the smtp entry rather than aliasing it', async () => {
    const deps = makeDeps({ inDesktop: vi.fn(() => true) });

    await submitMailSetup({ ...input, smtp: { ...smtp, secret: '', sameAsImap: true } }, deps);

    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:imap', 'hunter2');
    expect(deps.keychainSet).toHaveBeenCalledWith('ws-1', 'work-inbox:smtp', 'hunter2');
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3, 'smtp');
  });

  it('browser (dev) path hands both secrets over directly, touching no keychain', async () => {
    const deps = makeDeps();

    const outcome = await submitMailSetup({ ...input, smtp }, deps);

    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'hunter2', 3);
    expect(deps.api.setMailCredential).toHaveBeenCalledWith('work-inbox', 'smtp-only-secret', 3, 'smtp');
    expect(outcome).toEqual({ ok: true, devMode: true });
  });

  it('a failed IMAP credential handoff never hands the SMTP one over either', async () => {
    const deps = makeDeps({
      api: {
        setupMailAccount: vi.fn(async () => ok({ saved: true })),
        setMailCredential: vi.fn(async () => fail('workspace_changed'))
      }
    });

    const outcome = await submitMailSetup({ ...input, smtp }, deps);

    expect(outcome).toEqual({ ok: false, error: 'workspace_changed' });
    expect(deps.api.setMailCredential).toHaveBeenCalledTimes(1);
  });

  it('surfaces invalid_smtp from the RPC without handing any secret over', async () => {
    const deps = makeDeps({
      inDesktop: vi.fn(() => true),
      api: {
        setupMailAccount: vi.fn(async () => fail('invalid_smtp')),
        setMailCredential: vi.fn(async () => ok({ accepted: true }))
      }
    });

    const outcome = await submitMailSetup({ ...input, smtp }, deps);

    expect(outcome).toEqual({ ok: false, error: 'invalid_smtp' });
    expect(deps.keychainSet).not.toHaveBeenCalled();
    expect(deps.api.setMailCredential).not.toHaveBeenCalled();
  });
});

// `invalid_smtp` comes back from the RPC with NO reason detail (Task 2
// handoff), so everything checkable client-side is checked here — otherwise
// a typo'd port/security pair is a dead end for the user.
describe('smtpFormError', () => {
  const valid: MailSetupSmtpInput = {
    host: 'smtp.example.com',
    port: 587,
    security: '',
    username: 'mara@example.com',
    from: '',
    fromName: '',
    secret: 'smtp-secret',
    sameAsImap: false
  };

  it('accepts a well-formed block (blank security defaults from the port)', () => {
    expect(smtpFormError(valid)).toBeNull();
    expect(smtpFormError({ ...valid, port: 465 })).toBeNull();
    expect(smtpFormError({ ...valid, port: 587, security: 'starttls' })).toBeNull();
    expect(smtpFormError({ ...valid, port: 465, security: 'tls' })).toBeNull();
    expect(smtpFormError({ ...valid, port: 2525, security: 'tls' })).toBeNull();
  });

  it('requires a host and a username', () => {
    expect(smtpFormError({ ...valid, host: '  ' })).toBe('Enter the SMTP server host.');
    expect(smtpFormError({ ...valid, username: '' })).toBe('Enter the SMTP username.');
  });

  it('requires a positive port', () => {
    expect(smtpFormError({ ...valid, port: 0 })).toBe('Enter a valid SMTP port.');
    expect(smtpFormError({ ...valid, port: Number.NaN })).toBe('Enter a valid SMTP port.');
  });

  // Mirrors `Valea.Mail.Settings`'s port convention exactly (587↔starttls,
  // 465↔tls; any other port must state security explicitly).
  it('enforces the port/security convention', () => {
    expect(smtpFormError({ ...valid, port: 587, security: 'tls' })).toBe(
      'Port 587 uses STARTTLS. Pick STARTTLS, or use port 465 for TLS.'
    );
    expect(smtpFormError({ ...valid, port: 465, security: 'starttls' })).toBe(
      'Port 465 uses TLS. Pick TLS, or use port 587 for STARTTLS.'
    );
    expect(smtpFormError({ ...valid, port: 2525, security: '' })).toBe(
      'Pick a security setting — only ports 587 and 465 have a default.'
    );
  });

  // The backend refuses a bare login with no explicit From (`smtp.from`
  // defaults to `smtp.username`, which must be a single addr-spec).
  it('requires an explicit From when the username is not an email address', () => {
    expect(smtpFormError({ ...valid, username: 'mara' })).toBe(
      'This username is not an email address, so enter the From address to send as.'
    );
    expect(smtpFormError({ ...valid, username: 'mara', from: 'mara@example.com' })).toBeNull();
  });

  it('rejects a From that is not a single address', () => {
    expect(smtpFormError({ ...valid, from: 'Mara <mara@example.com>' })).toBe(
      'From must be a single email address, like you@example.com.'
    );
    expect(smtpFormError({ ...valid, from: 'a@b.co, c@d.co' })).toBe(
      'From must be a single email address, like you@example.com.'
    );
  });

  it('rejects a display name carrying a line break', () => {
    expect(smtpFormError({ ...valid, fromName: 'Mara\nVance' })).toBe(
      'The display name cannot contain line breaks.'
    );
  });

  it('requires a password unless the IMAP one is being copied', () => {
    expect(smtpFormError({ ...valid, secret: '' })).toBe('Enter the SMTP password.');
    expect(smtpFormError({ ...valid, secret: '', sameAsImap: true })).toBeNull();
  });

  it("edit mode allows a blank password — it means 'keep the stored one'", () => {
    expect(smtpFormError({ ...valid, secret: '' }, 'edit')).toBeNull();
  });
});

describe('mailSetupErrorMessage', () => {
  it.each([
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['invalid_slug', 'Account id must be lowercase letters, digits, and dashes (up to 32 characters).'],
    ['identity_mismatch', 'A different account already owns this folder on disk. Purge it first from the account list.'],
    ['invalid_smtp', 'The SMTP details were rejected. Check the host, port, security, and From address.']
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

// -- recovery-row shaping (windows-support spec C1 / T8 review) ---------------
//
// `SetupPanel`'s recovery block used to branch on `state` alone, which meant
// a store blocked for a CORRUPT `.account` (an unreadable
// `maildir_separator`) got identity-mismatch copy and a "Purge local files…"
// button — the exact wrong remedy for a one-file metadata problem. The
// branch lives here now so both arms are testable without a render harness.
describe('accountRecovery', () => {
  function status(state: string, lastError: string | null = null): Parameters<typeof accountRecovery>[0] {
    return { account: 'mara', state, lastError };
  }

  it('offers purge for a REAL identity mismatch', () => {
    const recovery = accountRecovery(status('identity_mismatch', null));

    expect(recovery?.kind).toBe('identity_mismatch');
    expect(recovery?.actions).toEqual(['purge']);
    expect(recovery?.message).toMatch(/different account identity/i);
  });

  it('does NOT offer purge for a corrupt .account, and names the file', () => {
    const recovery = accountRecovery(status('identity_mismatch', CORRUPT_ACCOUNT_META_ERROR));

    expect(recovery?.kind).toBe('corrupt_account_meta');
    expect(recovery?.actions).toEqual([]);
    expect(recovery?.message).toContain('sources/mail/mara/.account');
    expect(recovery?.message).toMatch(/repair|restore/i);
    expect(recovery?.message).not.toMatch(/purge/i);
    // Never the engine's raw string.
    expect(recovery?.message).not.toBe(CORRUPT_ACCOUNT_META_ERROR);
  });

  it('keeps re-adopt + purge for a replaced mailbox, whatever the lastError', () => {
    const recovery = accountRecovery(status('mailbox_replaced', CORRUPT_ACCOUNT_META_ERROR));

    expect(recovery?.kind).toBe('mailbox_replaced');
    expect(recovery?.actions).toEqual(['readopt', 'purge']);
  });

  it('is null for every non-recovery state (the row keeps its normal affordances)', () => {
    expect(accountRecovery(status('idle'))).toBeNull();
    expect(accountRecovery(status('auth_failed', 'authentication failed'))).toBeNull();
    expect(accountRecovery(status('syncing'))).toBeNull();
  });
});

describe('isCorruptAccountMeta', () => {
  it('matches the engine string byte-for-byte and nothing else', () => {
    expect(isCorruptAccountMeta(CORRUPT_ACCOUNT_META_ERROR)).toBe(true);
    expect(isCorruptAccountMeta('invalid maildir_separator')).toBe(false);
    expect(isCorruptAccountMeta('authentication failed')).toBe(false);
    expect(isCorruptAccountMeta(null)).toBe(false);
    expect(isCorruptAccountMeta(undefined)).toBe(false);
  });
});


// -- M6 task 16: mailbox sign-in ---------------------------------------------

describe('mailOauthProvider', () => {
  it('routes the Google and Microsoft IMAP hosts, case- and whitespace-insensitively', () => {
    expect(mailOauthProvider('imap.gmail.com')).toBe('gmail');
    expect(mailOauthProvider('imap.googlemail.com')).toBe('gmail');
    expect(mailOauthProvider('  IMAP.Gmail.COM ')).toBe('gmail');

    expect(mailOauthProvider('outlook.office365.com')).toBe('microsoft');
    expect(mailOauthProvider('outlook.office.com')).toBe('microsoft');
    expect(mailOauthProvider('imap-mail.outlook.com')).toBe('microsoft');
    expect(mailOauthProvider('Outlook.Office365.com')).toBe('microsoft');
  });

  it('leaves every other host on the password route', () => {
    for (const host of ['imap.fastmail.com', 'mail.example.com', 'outlook.example.com', '', '   ']) {
      expect(mailOauthProvider(host)).toBeNull();
    }
    expect(mailOauthProvider(null)).toBeNull();
    expect(mailOauthProvider(undefined)).toBeNull();
  });

  it('answers a MISS for inherited object keys (why the table is a Map)', () => {
    expect(mailOauthProvider('constructor')).toBeNull();
    expect(mailOauthProvider('toString')).toBeNull();
    expect(mailOauthProvider('__proto__')).toBeNull();
  });

  it('labels the provider as a human reads it, not as its host is spelled', () => {
    expect(mailOauthProviderLabel('gmail')).toBe('Google');
    expect(mailOauthProviderLabel('microsoft')).toBe('Microsoft');
    expect(mailOauthSignInLabel('imap.gmail.com')).toBe('Sign in with Google');
    expect(mailOauthSignInLabel('outlook.office365.com')).toBe('Sign in with Microsoft');
    expect(mailOauthSignInLabel('imap.fastmail.com')).toBeNull();
  });
});

describe('needsMailSignIn', () => {
  const oauth = { auth: 'oauth2' as const, state: 'idle', credential: 'present' as const, valid: true };

  it('is true for an expired sign-in AND for a missing one', () => {
    expect(needsMailSignIn({ ...oauth, state: 'reauth_required' })).toBe(true);
    // The abandoned-consent case: the account was written, the browser tab was
    // closed. Without this the row would sit there reading "Up to date".
    expect(needsMailSignIn({ ...oauth, credential: 'missing' })).toBe(true);
    // ...and after a restart with nothing in the keychain, the same shape.
    expect(needsMailSignIn({ ...oauth, state: 'inactive', credential: 'missing' })).toBe(true);
  });

  it('is false for a working oauth2 account', () => {
    expect(needsMailSignIn(oauth)).toBe(false);
    expect(needsMailSignIn({ ...oauth, state: 'syncing' })).toBe(false);
  });

  it('never offers a sign-in for a password account, however broken', () => {
    const password = { ...oauth, auth: 'password' as const };
    expect(needsMailSignIn(password)).toBe(false);
    expect(needsMailSignIn({ ...password, state: 'auth_failed', credential: 'missing' })).toBe(false);
    // Not even for the impossible combination of a password account parked in
    // the oauth state — a password is what fixes that one.
    expect(needsMailSignIn({ ...password, state: 'reauth_required' })).toBe(false);
  });

  it('never offers one for an invalid-config entry (there is no engine to sign into)', () => {
    expect(needsMailSignIn({ ...oauth, valid: false, state: 'invalid_config', credential: 'missing' })).toBe(
      false
    );
  });
});

describe('startMailSignIn', () => {
  function signInDeps(result: ApiResult<{ url?: unknown }>) {
    return {
      api: { startMailOauth: vi.fn(async (_account: string, _generation: number) => result) },
      openUrl: vi.fn((_url: string | null) => {})
    };
  }

  it('mints the consent URL and hands it to the reserved tab', async () => {
    const deps = signInDeps(ok({ url: 'https://accounts.google.com/o/oauth2/v2/auth?x=1' }));

    expect(await startMailSignIn('mara', 7, deps)).toEqual({ ok: true });
    expect(deps.api.startMailOauth).toHaveBeenCalledWith('mara', 7);
    expect(deps.openUrl).toHaveBeenCalledWith('https://accounts.google.com/o/oauth2/v2/auth?x=1');
  });

  it('CLOSES the reserved tab on a refusal rather than leaving a blank one parked', async () => {
    const deps = signInDeps(fail('oauth_not_configured'));

    expect(await startMailSignIn('mara', 7, deps)).toEqual({ ok: false, error: 'oauth_not_configured' });
    expect(deps.openUrl).toHaveBeenCalledWith(null);
  });

  it('treats a missing or non-string url as a failure, not as a tab to open', async () => {
    for (const url of [undefined, null, '', 42]) {
      const deps = signInDeps(ok({ url }));
      expect(await startMailSignIn('mara', 7, deps)).toEqual({ ok: false, error: 'no_url' });
      expect(deps.openUrl).toHaveBeenCalledWith(null);
    }
  });

  it('names the refusals a user can act on', () => {
    expect(mailSignInErrorMessage('oauth_unsupported')).toMatch(/password/i);
    expect(mailSignInErrorMessage('oauth_not_configured')).toMatch(/oauth_client_id/);
    expect(mailSignInErrorMessage('not_oauth')).toMatch(/password/i);
    expect(mailSignInErrorMessage('workspace_changed')).toMatch(/Reopen/);
    expect(mailSignInErrorMessage('not_found')).toBe('No such account.');
    expect(mailSignInErrorMessage('no_url')).toMatch(/try again/i);
    expect(mailSignInErrorMessage('something-new')).toMatch(/try again/i);
  });
});

// The keychain half of removing an account: `remove_mail_account` deletes
// the config entry, and the OS keychain entries are this side's to clean up
// (the backend cannot reach them). Same injected-deps shape as
// `submitMailSetup` above — no vi.mock needed.
describe('removeMailAccountAndForget', () => {
  function makeRemovalDeps(overrides: Partial<MailRemovalDeps> = {}): MailRemovalDeps {
    return {
      api: { removeMailAccount: vi.fn(async () => ok({ removed: true })) },
      inDesktop: vi.fn(() => true),
      workspaceId: vi.fn(() => 'ws-1'),
      keychainDelete: vi.fn(async () => {}),
      ...overrides
    };
  }

  it('deletes all three keychain slots after the backend confirms the removal', async () => {
    const deps = makeRemovalDeps();

    const result = await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(deps.api.removeMailAccount).toHaveBeenCalledWith('work-inbox', 3);
    // Keyed by SLUG, not by login, and under the workspace UUID — the exact
    // keys `submitMailSetup`/`persistMailOauthToken` write and
    // `resupplySlot` reads back.
    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-1', 'work-inbox:imap');
    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-1', 'work-inbox:smtp');
    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-1', 'work-inbox:oauth');
    expect(deps.keychainDelete).toHaveBeenCalledTimes(3);
    expect(result).toEqual({ ok: true, data: { removed: true } });
  });

  // All three slots regardless of the account's auth mode: an account that
  // was edited between a password and a provider sign-in has entries from
  // both, and this function is never told which mode it is removing.
  it('deletes the slots strictly AFTER the removal RPC, never before', async () => {
    const order: string[] = [];
    const deps = makeRemovalDeps({
      api: {
        removeMailAccount: vi.fn(async () => {
          order.push('removeMailAccount');
          return ok({ removed: true });
        })
      },
      keychainDelete: vi.fn(async (_ws: string, username: string) => {
        order.push(`keychainDelete:${username}`);
      })
    });

    await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(order).toEqual([
      'removeMailAccount',
      'keychainDelete:work-inbox:imap',
      'keychainDelete:work-inbox:smtp',
      'keychainDelete:work-inbox:oauth'
    ]);
  });

  // The account is still configured after a refusal — stripping its
  // credentials would break an account the user still has.
  it('touches nothing when the backend REFUSES the removal', async () => {
    const deps = makeRemovalDeps({
      api: { removeMailAccount: vi.fn(async () => fail('account_active')) }
    });

    const result = await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(result).toEqual({ ok: false, error: 'account_active' });
    expect(deps.keychainDelete).not.toHaveBeenCalled();
  });

  // Best-effort, exactly like the `keychainSet` writes: a keychain that
  // refuses (locked, no backend, a bridge that throws) must not turn a
  // removal that already happened into a failure the user sees.
  it('still reports success when keychainDelete REJECTS, and tries every slot', async () => {
    const deps = makeRemovalDeps({
      keychainDelete: vi.fn(async () => {
        throw new Error('keychain unavailable');
      })
    });

    const result = await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(result).toEqual({ ok: true, data: { removed: true } });
    expect(deps.keychainDelete).toHaveBeenCalledTimes(3);
  });

  it('reads the workspace id BEFORE the removal — the last account takes it with it', async () => {
    let accountRows = ['work-inbox'];
    const deps = makeRemovalDeps({
      api: {
        removeMailAccount: vi.fn(async () => {
          // What the store looks like once the row is gone.
          accountRows = [];
          return ok({ removed: true });
        })
      },
      workspaceId: vi.fn(() => (accountRows.length > 0 ? 'ws-1' : null))
    });

    await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-1', 'work-inbox:imap');
    expect(deps.keychainDelete).toHaveBeenCalledTimes(3);
  });

  it('skips the keychain entirely in the browser (dev) — there is none to clean', async () => {
    const deps = makeRemovalDeps({ inDesktop: vi.fn(() => false) });

    const result = await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(result).toEqual({ ok: true, data: { removed: true } });
    expect(deps.api.removeMailAccount).toHaveBeenCalledWith('work-inbox', 3);
    expect(deps.workspaceId).not.toHaveBeenCalled();
    expect(deps.keychainDelete).not.toHaveBeenCalled();
  });

  it('still removes the account when no workspace id is known', async () => {
    const deps = makeRemovalDeps({ workspaceId: vi.fn(() => null) });

    const result = await removeMailAccountAndForget('work-inbox', 3, deps);

    expect(result).toEqual({ ok: true, data: { removed: true } });
    expect(deps.keychainDelete).not.toHaveBeenCalled();
  });

  // The INVALID-CONFIG case end to end, wired the way `SetupPanel` wires it:
  // no row carries a workspace id, so without the store floor every delete
  // would be skipped silently — on the one account people actually remove.
  it('still deletes the slots when no account row carries a workspace id', async () => {
    const rows = [{ workspaceId: null }, { workspaceId: null }];
    const deps = makeRemovalDeps({
      workspaceId: () => mailKeychainWorkspaceId(rows, 'ws-store')
    });

    await removeMailAccountAndForget('broken', 3, deps);

    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-store', 'broken:imap');
    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-store', 'broken:smtp');
    expect(deps.keychainDelete).toHaveBeenCalledWith('ws-store', 'broken:oauth');
    expect(deps.keychainDelete).toHaveBeenCalledTimes(3);
  });
});

// `mail_status` returns two row shapes — engine-backed rows carry a
// `workspace_id`, invalid-config rows do not (`Valea.Api.Mail`) — so the
// keychain key cannot come from the rows alone.
describe('mailKeychainWorkspaceId', () => {
  it('prefers the row value — the Engine wrote the entries under exactly that id', () => {
    expect(mailKeychainWorkspaceId([{ workspaceId: 'ws-row' }], 'ws-store')).toBe('ws-row');
  });

  it('skips rows that carry none and takes the first that does', () => {
    expect(
      mailKeychainWorkspaceId([{ workspaceId: null }, { workspaceId: 'ws-row' }], 'ws-store')
    ).toBe('ws-row');
  });

  it('falls back to the workspace store when NO row carries one (invalid_config, or pre-activation)', () => {
    expect(mailKeychainWorkspaceId([{ workspaceId: null }], 'ws-store')).toBe('ws-store');
    expect(mailKeychainWorkspaceId([], 'ws-store')).toBe('ws-store');
  });

  it('is null only when neither source has one (no workspace open)', () => {
    expect(mailKeychainWorkspaceId([{ workspaceId: null }], null)).toBeNull();
    expect(mailKeychainWorkspaceId([], null)).toBeNull();
  });
});
