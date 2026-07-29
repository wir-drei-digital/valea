import { describe, it, expect, vi, afterEach } from 'vitest';
import {
  MAIL_SLUG_RE,
  mailSlugValid,
  accountLabel,
  folderBadge,
  messageSeen,
  filterMessagesByRead,
  folderFlagsLine,
  relativeTime,
  fromLabel,
  subjectLabel,
  messageHref,
  accountSwitchHref,
  targetAccount,
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
  sha256Hex,
  sendConfirmSummary,
  sendReviewExplanation,
  sendErrorMessage,
  sendGateAfterSendFailure,
  sendGateAfterReloadFailure,
  canSendDraft,
  draftNoticeMessage,
  canReviseDraft,
  reviseOutcomeMessage,
  reviseErrorMessage,
  NO_HOST_ICM_MESSAGE
} from './mail-shapes';
import {
  normalizeMailDraft,
  normalizeMailDraftReview,
  normalizeMailAccountStatus,
  type MailAccountStatus
} from '$lib/stores/mail.svelte';

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

describe('messageSeen / filterMessagesByRead', () => {
  const seen = { flags: 'FS' };
  const unseen = { flags: 'F' };
  const noFlags = { flags: null };

  it('reads the maildir S flag; absent/null flags mean unread', () => {
    expect(messageSeen(seen)).toBe(true);
    expect(messageSeen(unseen)).toBe(false);
    expect(messageSeen(noFlags)).toBe(false);
    expect(messageSeen({})).toBe(false);
  });

  it("'all' passes everything; 'unread'/'read' partition on the S flag", () => {
    const messages = [seen, unseen, noFlags];
    expect(filterMessagesByRead(messages, 'all')).toEqual(messages);
    expect(filterMessagesByRead(messages, 'unread')).toEqual([unseen, noFlags]);
    expect(filterMessagesByRead(messages, 'read')).toEqual([seen]);
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

describe('messageHref', () => {
  it('qualifies the link with the account and escapes both params', () => {
    expect(messageHref('personal', 'a b')).toBe('/mail?account=personal&message=a%20b');
    expect(messageHref('work-2', '1465.M2#x')).toBe('/mail?account=work-2&message=1465.M2%23x');
  });
});

// The switcher↔effect contract. Switching accounts is a NAVIGATION: the
// route's selection effect tracks `mailStore.selectedAccount`, so a switcher
// that wrote the store first would re-run that effect while `page.url` still
// named the OLD account — the effect would read the stale `?account=`, switch
// back, and the user's choice would snap away. These two helpers are the two
// halves of "the URL leads": what the switcher navigates to, and how the
// effect resolves the account from the URL.
describe('accountSwitchHref', () => {
  it('carries the new account and drops an open message', () => {
    expect(accountSwitchHref(new URL('http://app/mail?account=mara&message=m1'), 'zoe')).toBe(
      '/mail?account=zoe'
    );
    expect(accountSwitchHref(new URL('http://app/mail'), 'zoe')).toBe('/mail?account=zoe');
  });

  it('keeps the drafts panel open across the switch', () => {
    expect(accountSwitchHref(new URL('http://app/mail?drafts=1'), 'zoe')).toBe('/mail?account=zoe&drafts=1');
  });
});

describe('targetAccount', () => {
  const accounts = [{ account: 'mara' }, { account: 'zoe' }];

  it('lets the URL lead when it names a configured account', () => {
    expect(targetAccount('zoe', 'mara', accounts)).toBe('zoe');
  });

  it('falls back to the store when the URL names no configured account', () => {
    expect(targetAccount('gone', 'mara', accounts)).toBe('mara');
  });

  it('takes a deep link at its word before the account list has loaded', () => {
    expect(targetAccount('zoe', null, [])).toBe('zoe');
  });

  it('is the store selection when the URL says nothing', () => {
    expect(targetAccount(null, 'mara', accounts)).toBe('mara');
    expect(targetAccount(null, null, [])).toBeNull();
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
    ['mailbox_replaced', 'Mailbox replaced, needs re-adopt'],
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

  // windows-support spec C1: `Valea.Mail.Engine`'s `activate_with_separator`
  // blocks the account inert with this EXACT `last_error` when
  // `.account`'s `maildir_separator` is unreadable. It shares the
  // `identity_mismatch` state (whose panel copy offers a purge), so the
  // error line has to say the file — not the mail — is the problem.
  const SEPARATOR_ERROR = 'invalid maildir_separator in .account';

  it("rewrites the engine's raw invalid-separator error into copy about the .account file", () => {
    const text = syncErrorText({ ...baseStatus, lastError: SEPARATOR_ERROR }, null);

    expect(text).not.toBe(SEPARATOR_ERROR);
    expect(text).toContain('.account');
    expect(text).toMatch(/restore|fix/i);
    // The recovery is repairing one metadata file; the mail underneath is fine.
    expect(text).not.toMatch(/purge/i);
  });

  it('still prefers a local request error over the rewritten one', () => {
    expect(syncErrorText({ ...baseStatus, lastError: SEPARATOR_ERROR }, 'No workspace is open.')).toBe(
      'No workspace is open.'
    );
  });

  it('passes through any other engine error verbatim (unknown strings are not swallowed)', () => {
    expect(syncErrorText({ ...baseStatus, lastError: 'connection closed by peer' }, null)).toBe(
      'connection closed by peer'
    );
    // The lookup key is backend-supplied: an inherited object property must
    // never be mistaken for copy (hence a Map, not a record literal).
    expect(syncErrorText({ ...baseStatus, lastError: 'toString' }, null)).toBe('toString');
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
      'The message changed on the server. Sync and try again.'
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
    ['sending', 'Sending…', 'busy'],
    ['send_review', 'Needs your answer', 'warn'],
    ['sent', 'Sent', 'ok'],
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
    ['content_changed', 'The draft changed since you opened it. Review it again, then push.'],
    ['duplicate_active', 'This draft is already being pushed.'],
    ['push_failed', "The push failed before anything was sent. It's safe to try again."],
    ['anything_else', 'Could not push the draft. Check the account state and try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(pushErrorMessage(code)).toBe(expected);
  });
});

// -- send (spec G) ------------------------------------------------------------

describe('sendConfirmSummary', () => {
  const review = normalizeMailDraftReview({
    content: 'Body.',
    contentHash: 'h',
    recipients: {
      to: [
        { name: 'Alex', email: 'alex@example.com' },
        { name: null, email: 'bo@example.com' }
      ],
      cc: [{ name: null, email: 'cc@example.com' }],
      bcc: [{ name: null, email: 'bcc@example.com' }]
    },
    subject: 'Re: Kickoff',
    threading: { in_reply_to: '<m1@example.com>', references: [] },
    threadingWarning: false,
    identity: { from: 'mara@example.com', from_name: 'Mara Vance', account: 'mara' },
    reviewFingerprint: 'fp',
    smtpConfigured: true
  });

  it('lists the parsed recipient set, the subject, and the config-owned sending identity', () => {
    expect(sendConfirmSummary(review)).toEqual([
      'To: Alex <alex@example.com>, bo@example.com',
      'Cc: cc@example.com',
      'Bcc: bcc@example.com',
      'Subject: Re: Kickoff',
      'From: Mara Vance <mara@example.com> · mara'
    ]);
  });

  it('omits empty Cc/Bcc lines and names a missing subject', () => {
    const bare = normalizeMailDraftReview({
      contentHash: 'h',
      recipients: { to: [{ name: null, email: 'alex@example.com' }], cc: [], bcc: [] },
      subject: '',
      identity: { from: 'mara@example.com', from_name: null, account: 'mara' },
      smtpConfigured: true
    });

    expect(sendConfirmSummary(bare)).toEqual([
      'To: alex@example.com',
      'Subject: (no subject)',
      'From: mara@example.com · mara'
    ]);
  });

  // Threading is part of the review contract even though it lives outside
  // the draft bytes — an unmirrored `in_reply_to` composes WITHOUT threading
  // headers, which the human has to be told before confirming.
  it('appends the threading warning line only when the reference could not be resolved', () => {
    const warned = normalizeMailDraftReview({
      contentHash: 'h',
      recipients: { to: [{ name: null, email: 'alex@example.com' }], cc: [], bcc: [] },
      subject: 'Re: Kickoff',
      threading: null,
      threadingWarning: true,
      identity: { from: 'mara@example.com', from_name: null, account: 'mara' },
      smtpConfigured: true
    });

    const lines = sendConfirmSummary(warned);
    expect(lines[lines.length - 1]).toBe(
      "The message this replies to isn't mirrored here, so this will start a new thread."
    );
    expect(sendConfirmSummary(review)).not.toContain(
      "The message this replies to isn't mirrored here, so this will start a new thread."
    );
  });

  it('never claims a sending identity the account does not have', () => {
    const pushOnly = normalizeMailDraftReview({
      contentHash: 'h',
      recipients: { to: [{ name: null, email: 'alex@example.com' }], cc: [], bcc: [] },
      subject: 'S',
      identity: { from: null, from_name: null, account: 'mara' },
      smtpConfigured: false
    });

    expect(sendConfirmSummary(pushOnly)).toContain('From: (no sending identity configured) · mara');
  });
});

describe('sendReviewExplanation', () => {
  it('states the gmail reconciliation evidence when Sent Mail was searched and came back empty', () => {
    expect(sendReviewExplanation('gmail_sent_checked_empty')).toBe(
      'Sent Mail was checked and found empty — this message most likely did not go out. ' +
        'Check your own Sent folder (and, if in doubt, the recipient), then tell Valea what you found.'
    );
  });

  // Every other notice covers BOTH profiles, and the frontend cannot tell
  // them apart from a notice alone: a generic account is never reconciled at
  // all (nothing is ever searched for it), so any "awaiting a mailbox
  // connection / still reconciling" wording would be plainly false for one of
  // the two — at the exact moment the user decides whether mail went out.
  // The honest fallback claims no check of any kind.
  it('explains an unconfirmed parked send without claiming anything was checked', () => {
    const unchecked =
      'The server never confirmed this send, and nothing has been checked automatically. ' +
      'Check your own Sent folder (and, if in doubt, the recipient), then tell Valea what you found.';

    expect(sendReviewExplanation('send_unknown: :closed')).toBe(unchecked);
    expect(sendReviewExplanation(null)).toBe(unchecked);
    expect(sendReviewExplanation('send_unknown: :closed')).not.toMatch(/reconcil|reachable|awaiting/i);
  });
});

// The drift gate: once the server has refused the review on screen, Send must
// not come back until a FRESH review has actually arrived.
describe('sendGateAfterSendFailure / sendGateAfterReloadFailure', () => {
  it('withholds Send for the two drift refusals, which a reload fixes', () => {
    for (const code of ['re_review_required', 'content_changed']) {
      expect(sendGateAfterSendFailure(code)).toEqual({ error: sendErrorMessage(code), reloadable: true });
    }
  });

  it('leaves Send armed for a failure a reload cannot fix', () => {
    expect(sendGateAfterSendFailure('no_smtp_credential')).toEqual({
      error: sendErrorMessage('no_smtp_credential'),
      reloadable: false
    });
  });

  // The regression this pins: a FAILED reload must not drop the gate. Doing
  // so re-arms Send against the very review the server just refused —
  // a confirm guaranteed to fail, offered as though it were fine.
  it('keeps Send withheld when the reload itself fails, showing the reload error', () => {
    const refused = sendGateAfterSendFailure('re_review_required');

    expect(sendGateAfterReloadFailure(refused, 'not_found')).toEqual({
      error: sendErrorMessage('not_found'),
      reloadable: true
    });
  });

  it('never ARMS the gate on its own — it only ever preserves what it was handed', () => {
    expect(sendGateAfterReloadFailure({ error: null, reloadable: false }, 'workspace_changed')).toEqual({
      error: sendErrorMessage('workspace_changed'),
      reloadable: false
    });
  });
});

describe('draftNoticeMessage', () => {
  it('spells out the ledger notices a row can carry', () => {
    expect(draftNoticeMessage('earlier_revision_sent')).toBe(
      'An earlier revision of this draft was sent. This file has changed since.'
    );
    expect(draftNoticeMessage('status_forged')).toBe(
      "This draft's status was written by something other than Valea, so it is being ignored."
    );
    expect(draftNoticeMessage('sent_copy_failed')).toBe(
      "This was sent, but the copy for your Sent folder didn't land."
    );
  });

  // A rejected send's notice is a composed reason string (redacted transport
  // detail included) — it is already the most specific thing we have, so it
  // passes through rather than being flattened into a generic sentence.
  it('passes an unmapped reason through, and drops an absent one', () => {
    expect(draftNoticeMessage('rejected_recipients: alex@example.com: 550 no such user')).toBe(
      'rejected_recipients: alex@example.com: 550 no such user'
    );
    expect(draftNoticeMessage(null)).toBeNull();
  });
});

describe('sendErrorMessage', () => {
  it.each([
    [
      're_review_required',
      'The sending identity or the thread changed while you were reviewing. Reload the review, then confirm again.'
    ],
    ['content_changed', 'The draft changed since you opened it. Reload the review, then send.'],
    ['draft_too_large', 'This draft is too large to send.'],
    ['smtp_not_configured', 'Add SMTP details for this account before sending.'],
    ['no_smtp_credential', 'Enter your SMTP password first.'],
    ['not_reviewable', 'This send was already resolved.'],
    ['not_retryable', 'There is nothing left to retry for this message.'],
    [
      'sent_copy_deferred',
      'The message was sent, but its Sent copy could not be filed — the mailbox is not reachable right now. Try again once it reconnects.'
    ],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['anything_else', 'Could not send the draft. Check the account state and try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(sendErrorMessage(code)).toBe(expected);
  });
});

describe('canSendDraft', () => {
  const smtpAccount = normalizeMailAccountStatus({
    account: 'mara',
    configured: true,
    credential: 'present',
    state: 'idle',
    smtp_configured: true,
    smtp_credential: 'present'
  });
  const draftRow = (overrides: Record<string, unknown> = {}) =>
    normalizeMailDraft({
      account: 'mara',
      name: 'reply.md',
      path: 'p',
      status_display: 'draft',
      parsed_recipients: { to: [{ name: null, email: 'a@b.co' }], cc: [], bcc: [], subject: 'S' },
      ...overrides
    });

  it('is true for a parsed draft on an SMTP-configured account', () => {
    expect(canSendDraft(draftRow(), smtpAccount)).toBe(true);
  });

  // `pushed` is a badge, never the primary state: a draft that was pushed
  // and then edited is still sendable.
  it('stays true for a draft carrying the pushed badge', () => {
    expect(canSendDraft(draftRow({ pushed: true }), smtpAccount)).toBe(true);
  });

  it('is false for a push-only account, an unknown account, an unparseable draft, or any non-draft state', () => {
    expect(canSendDraft(draftRow(), normalizeMailAccountStatus({ account: 'mara' }))).toBe(false);
    expect(canSendDraft(draftRow(), null)).toBe(false);
    expect(canSendDraft(draftRow({ parsed_recipients: { invalid: 'link_unsafe' } }), smtpAccount)).toBe(false);
    for (const state of ['pushing', 'pushed', 'sending', 'send_review', 'sent', 'needs_review']) {
      expect(canSendDraft(draftRow({ status_display: state }), smtpAccount)).toBe(false);
    }
  });

  // A rejected send reverts the draft to `draft` with the reason surfaced,
  // so the affordance has to come back — same as the push path's retry.
  it('is true again for a rejected row (the state reverts to draft, the notice carries the reason)', () => {
    expect(canSendDraft(draftRow({ status_display: 'draft', notice: 'send_failed' }), smtpAccount)).toBe(true);
  });
});

describe('canReviseDraft', () => {
  it('is offered for every settled row, including an unparseable one', () => {
    for (const state of ['draft', 'pushed', 'sent', 'rejected', 'needs_review']) {
      expect(canReviseDraft({ statusDisplay: state })).toBe(true);
    }
  });

  // A claim in flight is hash-bound to bytes already snapshotted — inviting
  // an edit there would only earn a `content_changed` refusal.
  it('is withheld while a push or send is actually in flight', () => {
    for (const state of ['pushing', 'sending', 'send_review']) {
      expect(canReviseDraft({ statusDisplay: state })).toBe(false);
    }
  });
});

describe('reviseOutcomeMessage', () => {
  // Both outcomes lead the same way — the feedback is with an agent now —
  // because that is the part the user asked for. Which session it landed in
  // is the follow-on detail, not the headline.
  it('leads with the outcome and names where the feedback went', () => {
    expect(reviseOutcomeMessage('existing')).toBe('Sent to session — it was already working on this draft.');
    expect(reviseOutcomeMessage('new')).toBe('Sent to session — a new one is now on this draft.');
  });

  it('degrades to the bare outcome for an unknown routing', () => {
    expect(reviseOutcomeMessage('something_else')).toBe('Sent to session.');
  });
});

describe('reviseErrorMessage', () => {
  // `no_icm_available` is the backend's name for the same condition the panel
  // detects client-side when no mount can host a session — one sentence for
  // both, so the user never sees two spellings of one problem.
  it('maps no_icm_available to the same copy as the client-side no-mount case', () => {
    expect(reviseErrorMessage('no_icm_available')).toBe(NO_HOST_ICM_MESSAGE);
    expect(NO_HOST_ICM_MESSAGE).toBe('No enabled project can host the session. Enable one in the sidebar.');
  });

  it.each([
    ['not_found', 'This draft no longer exists.'],
    ['link_unsafe', 'This draft file is not a regular file.'],
    ['harness_unavailable', "The assistant isn't ready — open Agent settings (gear in the sidebar) and run the checks."],
    ['workspace_not_open', 'No workspace is open.'],
    ['workspace_changed', 'Your workspace changed. Reopen it and try again.'],
    ['anything_else', 'Could not send the feedback. Please try again.']
  ])('maps error code=%s to a calm sentence', (code, expected) => {
    expect(reviseErrorMessage(code)).toBe(expected);
  });
});

describe('sha256Hex', () => {
  it('matches the backend content_hash encoding (lowercase hex, known vector)', async () => {
    // :crypto.hash(:sha256, "") |> Base.encode16(case: :lower)
    expect(await sha256Hex('')).toBe('e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855');
    expect(await sha256Hex('abc')).toBe('ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
  });
});
