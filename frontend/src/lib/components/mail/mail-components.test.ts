import { describe, it, expect, vi, afterEach } from 'vitest';
import {
  MAIL_SLUG_RE,
  mailSlugValid,
  accountLabel,
  folderBadge,
  folderFlagsLine,
  relativeTime,
  fromLabel,
  subjectLabel,
  addressLabel,
  addressListLabel,
  formatDateTime,
  attachmentsFromFrontmatter,
  formatBytes,
  mailStateLabel,
  mailMaintenanceErrorMessage,
  syncErrorText,
  syncNowErrorMessage,
  messageSessionPrompt,
  opResultMessage,
  cleanupPrompt,
  draftStatusBadge,
  draftRecipientsLine,
  pushErrorMessage,
  sha256Hex
} from './mail-shapes';
import { normalizeMailAccountStatus, type MailAccountStatus } from '$lib/stores/mail.svelte';

afterEach(() => {
  vi.useRealTimers();
});

describe('mailSlugValid', () => {
  it('accepts the backend grammar (^[a-z0-9][a-z0-9-]{0,31}$)', () => {
    expect(mailSlugValid('work')).toBe(true);
    expect(mailSlugValid('a')).toBe(true);
    expect(mailSlugValid('mara-2')).toBe(true);
    expect(mailSlugValid('0start')).toBe(true);
    expect(mailSlugValid('a'.repeat(32))).toBe(true);
  });

  it('rejects uppercase, leading dash, separators, traversal, and over-length ids', () => {
    expect(mailSlugValid('')).toBe(false);
    expect(mailSlugValid('Work')).toBe(false);
    expect(mailSlugValid('-lead')).toBe(false);
    expect(mailSlugValid('has space')).toBe(false);
    expect(mailSlugValid('has_underscore')).toBe(false);
    expect(mailSlugValid('../x')).toBe(false);
    expect(mailSlugValid('a'.repeat(33))).toBe(false);
    // the regex itself is anchored — a valid slug embedded in junk fails
    expect(MAIL_SLUG_RE.test('x\nwork')).toBe(false);
  });
});

describe('accountLabel', () => {
  it('is the bare slug for a valid account, marked inline for an invalid one', () => {
    expect(accountLabel({ account: 'work', valid: true })).toBe('work');
    expect(accountLabel({ account: 'broken', valid: false })).toBe('broken (invalid)');
  });
});

describe('folderBadge', () => {
  it('badges held folders and nothing else', () => {
    expect(folderBadge({ held: true })).toBe('held');
    expect(folderBadge({ held: false })).toBeNull();
  });
});

describe('folderFlagsLine', () => {
  it('joins folders and flags when both are present', () => {
    expect(folderFlagsLine({ folders: ['INBOX', 'Archive'], flags: 'S' })).toBe('INBOX, Archive · flags: S');
  });

  it('renders each part alone when the other is absent/blank', () => {
    expect(folderFlagsLine({ folders: ['INBOX'], flags: '' })).toBe('INBOX');
    expect(folderFlagsLine({ folders: [], flags: 'RS' })).toBe('flags: RS');
  });

  it('returns "" for null frontmatter, missing fields, or malformed values', () => {
    expect(folderFlagsLine(null)).toBe('');
    expect(folderFlagsLine({})).toBe('');
    expect(folderFlagsLine({ folders: 'nope', flags: 7 } as never)).toBe('');
  });
});

describe('fromLabel', () => {
  it('prefers fromName when present', () => {
    expect(fromLabel({ fromName: 'Priya Nair', fromEmail: 'priya@example.com' })).toBe('Priya Nair');
  });

  it('falls back to fromEmail when fromName is missing/blank', () => {
    expect(fromLabel({ fromName: null, fromEmail: 'priya@example.com' })).toBe('priya@example.com');
    expect(fromLabel({ fromName: '   ', fromEmail: 'priya@example.com' })).toBe('priya@example.com');
  });

  it('falls back to a placeholder when neither is present', () => {
    expect(fromLabel({ fromName: null, fromEmail: null })).toBe('(unknown sender)');
  });
});

describe('subjectLabel', () => {
  it('passes a non-empty subject through', () => {
    expect(subjectLabel('Coaching inquiry')).toBe('Coaching inquiry');
  });

  it('falls back to a placeholder for null/blank subjects', () => {
    expect(subjectLabel(null)).toBe('(no subject)');
    expect(subjectLabel(undefined)).toBe('(no subject)');
    expect(subjectLabel('   ')).toBe('(no subject)');
  });
});

describe('relativeTime', () => {
  it('returns "" for null/undefined/unparseable input', () => {
    expect(relativeTime(null)).toBe('');
    expect(relativeTime(undefined)).toBe('');
    expect(relativeTime('not-a-date')).toBe('');
  });

  it('formats a moment in the recent past relative to now', () => {
    vi.useFakeTimers();
    vi.setSystemTime(new Date('2026-07-10T12:05:00Z'));

    expect(relativeTime('2026-07-10T12:00:00Z')).toBe('5 minutes ago');
  });
});

describe('addressLabel', () => {
  it('renders "name <email>" when both are present', () => {
    expect(addressLabel({ name: 'Priya Nair', email: 'priya@example.com' })).toBe(
      'Priya Nair <priya@example.com>'
    );
  });

  it('falls back to just the name, or just the email, when the other is missing', () => {
    expect(addressLabel({ name: 'Priya Nair', email: null })).toBe('Priya Nair');
    expect(addressLabel({ name: null, email: 'priya@example.com' })).toBe('priya@example.com');
  });

  it('returns "" for null, non-object, or an address with neither field', () => {
    expect(addressLabel(null)).toBe('');
    expect(addressLabel(undefined)).toBe('');
    expect(addressLabel({ name: null, email: null })).toBe('');
  });
});

describe('addressListLabel', () => {
  it('joins multiple addresses with a comma', () => {
    expect(
      addressListLabel([
        { name: 'Priya Nair', email: 'priya@example.com' },
        { name: null, email: 'assistant@example.com' }
      ])
    ).toBe('Priya Nair <priya@example.com>, assistant@example.com');
  });

  it('returns "" for a non-array or empty array', () => {
    expect(addressListLabel(undefined)).toBe('');
    expect(addressListLabel([])).toBe('');
  });
});

describe('formatDateTime', () => {
  it('returns "" for null/undefined/unparseable input', () => {
    expect(formatDateTime(null)).toBe('');
    expect(formatDateTime(undefined)).toBe('');
    expect(formatDateTime('not-a-date')).toBe('');
  });

  it('formats a valid ISO8601 timestamp to a non-empty string', () => {
    expect(formatDateTime('2026-07-10T12:00:00Z')).not.toBe('');
  });
});

describe('attachmentsFromFrontmatter', () => {
  it('reads {filename, path, bytes} entries off frontmatter.attachments', () => {
    const frontmatter = {
      attachments: [{ filename: 'contract.pdf', path: 'sources/mail/attachments/m1/contract.pdf', bytes: 20480 }]
    };

    expect(attachmentsFromFrontmatter(frontmatter)).toEqual([
      { filename: 'contract.pdf', path: 'sources/mail/attachments/m1/contract.pdf', bytes: 20480 }
    ]);
  });

  it('drops malformed entries (missing filename/path) instead of throwing', () => {
    const frontmatter = { attachments: [{ filename: 'ok.pdf', path: 'p' }, { bytes: 5 }, null, 'x'] };

    expect(attachmentsFromFrontmatter(frontmatter)).toEqual([{ filename: 'ok.pdf', path: 'p', bytes: 0 }]);
  });

  it('returns [] for null frontmatter, a missing field, or a non-array value', () => {
    expect(attachmentsFromFrontmatter(null)).toEqual([]);
    expect(attachmentsFromFrontmatter({})).toEqual([]);
    expect(attachmentsFromFrontmatter({ attachments: 'nope' })).toEqual([]);
  });
});

describe('formatBytes', () => {
  it('renders bytes under 1024 as whole bytes', () => {
    expect(formatBytes(512)).toBe('512 B');
    expect(formatBytes(0)).toBe('0 B');
  });

  it('renders kilobytes with one decimal below 10, whole numbers at/above 10', () => {
    expect(formatBytes(2048)).toBe('2 KB');
    expect(formatBytes(1536)).toBe('1.5 KB');
    expect(formatBytes(20480)).toBe('20 KB');
  });

  it('renders megabytes once the value crosses 1024 KB', () => {
    expect(formatBytes(5 * 1024 * 1024)).toBe('5 MB');
  });

  it('never throws on negative or non-finite input', () => {
    expect(formatBytes(-5)).toBe('0 B');
    expect(formatBytes(Number.NaN)).toBe('0 B');
  });
});

describe('mailStateLabel', () => {
  it.each([
    ['idle', 'Up to date'],
    ['syncing', 'Syncing…'],
    ['auth_failed', 'Sign-in failed'],
    ['inactive', 'Not connected'],
    ['identity_mismatch', 'Folder belongs to a different account'],
    ['mailbox_replaced', 'Mailbox replaced — needs re-adopt'],
    ['invalid_config', 'Invalid configuration']
  ])('labels state=%s as %s', (state, expected) => {
    expect(mailStateLabel(state)).toBe(expected);
  });

  it('falls back to the raw state string for anything unrecognized, and to "Unknown" for null', () => {
    expect(mailStateLabel('a_future_state')).toBe('a_future_state');
    expect(mailStateLabel(null)).toBe('Unknown');
    expect(mailStateLabel(undefined)).toBe('Unknown');
  });
});

describe('mailMaintenanceErrorMessage', () => {
  it.each([
    ['confirmation_mismatch', "The confirmation text doesn't match."],
    ['account_active', 'This account is still running. Remove it from the config first, or wait for it to stop.'],
    ['not_held', 'That folder is not held anymore.'],
    ['mailbox_replaced', 'This account is blocked pending re-adopt.'],
    ['not_found', 'No such account.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['anything_else', 'The action failed. Check the account state and try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(mailMaintenanceErrorMessage(code)).toBe(expected);
  });
});

describe('syncErrorText', () => {
  const baseStatus: MailAccountStatus = normalizeMailAccountStatus({
    account: 'mara',
    configured: true,
    credential: 'present',
    state: 'auth_failed',
    last_error: 'authentication failed',
    username: 'mara@example.com',
    workspace_id: 'ws-1'
  });

  it('shows the engine-reported lastError when there is no local request error', () => {
    expect(syncErrorText(baseStatus, null)).toBe('authentication failed');
  });

  it('prefers a local request error (e.g. the sync-now RPC itself failing) over lastError', () => {
    expect(syncErrorText(baseStatus, 'Could not start a sync. Please try again.')).toBe(
      'Could not start a sync. Please try again.'
    );
  });

  it('returns null when neither is present', () => {
    expect(syncErrorText({ ...baseStatus, lastError: null }, null)).toBeNull();
    expect(syncErrorText(null, null)).toBeNull();
  });
});

describe('syncNowErrorMessage', () => {
  it.each([
    ['not_configured', 'Connect your mailbox first.'],
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['anything_else', 'Could not start a sync. Please try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(syncNowErrorMessage(code)).toBe(expected);
  });
});

describe('messageSessionPrompt', () => {
  it('references the granted path, the mail mount, and the no-send rule', () => {
    const prompt = messageSessionPrompt('/ws/sources/mail/mara/views/messages/m1.md', 'mail-mara');
    expect(prompt).toContain('`/ws/sources/mail/mara/views/messages/m1.md`');
    expect(prompt).toContain('`mail-mara`');
    expect(prompt).toContain('ops/pending/');
    expect(prompt).toContain('you cannot send anything');
  });
});

describe('opResultMessage', () => {
  it('is null for success outcomes', () => {
    expect(opResultMessage('accepted', null)).toBeNull();
    expect(opResultMessage('complete', null)).toBeNull();
  });

  it('maps known rejection reasons to calm sentences and falls back with the raw reason', () => {
    expect(opResultMessage('rejected', 'server_changed')).toBe(
      'The message changed on the server — sync and try again.'
    );
    expect(opResultMessage('rejected', 'no_credential')).toBe('Enter your mailbox password first.');
    expect(opResultMessage('rejected', 'weird_reason')).toBe('The action was rejected (weird_reason).');
    expect(opResultMessage('rejected', null)).toBe('The action was rejected.');
  });
});

describe('cleanupPrompt', () => {
  it('pins the plan-mandated text', () => {
    const prompt = cleanupPrompt('mara');
    expect(prompt).toContain("You have the mail account 'mara' mounted read-only at its mail mount.");
    expect(prompt).toContain('YAML ops file in ops/pending/');
    expect(prompt).toContain('(vocabulary: move, flag)');
    expect(prompt).toContain('Never modify maildir/ directly.');
    expect(prompt).toContain("Propose, don't over-file: when unsure, leave a message where it is.");
  });
});

describe('draftStatusBadge', () => {
  it.each([
    ['draft', 'Draft', 'neutral'],
    ['pushing', 'Pushing…', 'busy'],
    ['pushed', 'Pushed', 'ok'],
    ['needs_review', 'Needs review', 'warn'],
    ['rejected', 'Rejected', 'warn'],
    ['unknown_future', 'Draft', 'neutral']
  ])('maps %s to %s/%s', (state, label, tone) => {
    expect(draftStatusBadge(state)).toEqual({ label, tone });
  });
});

describe('draftRecipientsLine', () => {
  it('joins recipients and subject', () => {
    expect(
      draftRecipientsLine({
        to: [
          { name: 'Alex', email: 'alex@example.com' },
          { name: null, email: 'bo@example.com' }
        ],
        cc: [],
        bcc: [],
        subject: 'Kickoff'
      })
    ).toBe('To Alex <alex@example.com>, bo@example.com · Kickoff');
  });

  it('renders the invalid reason for an unparseable draft', () => {
    expect(draftRecipientsLine({ invalid: 'link_unsafe' })).toBe('Invalid draft (link_unsafe)');
  });

  it('falls back when there is nothing to show', () => {
    expect(draftRecipientsLine({ to: [], cc: [], bcc: [], subject: null })).toBe('(no recipients)');
  });
});

describe('pushErrorMessage', () => {
  it.each([
    ['hash_mismatch', 'The draft changed since you opened it — review it again, then push.'],
    ['duplicate_active', 'This draft is already being pushed.'],
    ['push_failed', "The push failed before anything was sent. It's safe to try again."],
    ['anything_else', 'Could not push the draft. Check the account state and try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(pushErrorMessage(code)).toBe(expected);
  });
});

describe('sha256Hex', () => {
  it('matches the backend content_hash encoding (lowercase hex, known vector)', async () => {
    // :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    expect(await sha256Hex('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});
