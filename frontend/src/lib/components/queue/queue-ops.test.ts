import { describe, expect, it } from 'vitest';
import {
  findDecidedItem,
  mailboxOpChip,
  mailboxOpLabel,
  mailboxOpRows,
  mailboxOpStatusText,
  normalizeDecidedItem,
  retryMailboxOpsErrorMessage
} from './queue-ops';

// Mirrors `Valea.Queue.list_decided/0`'s `decided_entry/2` shape — raw,
// snake_case (list_decided_items' `items` field is unconstrained).
const rawApproved = {
  run_id: '20260710T090000Z-abcd1234',
  decided: 'approved',
  title: 'Reply to Priya',
  kind: 'email_draft',
  mailbox_ops: {
    draft_append: { status: 'done' },
    archive_source: { status: 'pending' }
  },
  created_at: '2026-07-10T09:00:00Z'
};

describe('normalizeDecidedItem', () => {
  it('normalizes a raw decided entry', () => {
    const item = normalizeDecidedItem(rawApproved);
    expect(item).toEqual({
      runId: '20260710T090000Z-abcd1234',
      decided: 'approved',
      title: 'Reply to Priya',
      kind: 'email_draft',
      mailboxOps: rawApproved.mailbox_ops,
      createdAt: '2026-07-10T09:00:00Z',
      decision: null
    });
  });

  it('returns null for entries without a usable run_id', () => {
    expect(normalizeDecidedItem({})).toBeNull();
    expect(normalizeDecidedItem(null)).toBeNull();
    expect(normalizeDecidedItem('nope')).toBeNull();
  });

  it('defaults mailboxOps to null when absent (a non-email_draft decided item)', () => {
    const item = normalizeDecidedItem({ run_id: 'r1', decided: 'rejected', title: 'x', kind: 'note' });
    expect(item?.mailboxOps).toBeNull();
  });

  it('carries a rejection reason through (B6/B12)', () => {
    const item = normalizeDecidedItem({
      run_id: 'rr1',
      decided: 'rejected',
      title: 'Update x',
      kind: 'memory_update',
      decision: { reason: 'too pushy' }
    });
    expect(item?.decision).toEqual({ reason: 'too pushy' });
  });

  it('defaults decision to null when absent, blank, or malformed', () => {
    expect(normalizeDecidedItem({ run_id: 'r1', decided: 'approved' })?.decision).toBeNull();
    expect(
      normalizeDecidedItem({ run_id: 'r2', decided: 'rejected', decision: { reason: '   ' } })?.decision
    ).toBeNull();
    expect(normalizeDecidedItem({ run_id: 'r3', decided: 'rejected', decision: 'nope' })?.decision).toBeNull();
  });
});

describe('findDecidedItem', () => {
  it('finds the matching entry by run_id among several', () => {
    const other = { ...rawApproved, run_id: 'other-run' };
    const found = findDecidedItem([other, rawApproved], rawApproved.run_id);
    expect(found?.runId).toBe(rawApproved.run_id);
  });

  it('returns null when no entry matches', () => {
    expect(findDecidedItem([rawApproved], 'missing-run')).toBeNull();
  });

  it('skips unparseable entries while still finding a later match', () => {
    const found = findDecidedItem([{}, null, rawApproved], rawApproved.run_id);
    expect(found?.runId).toBe(rawApproved.run_id);
  });
});

describe('mailboxOpLabel', () => {
  it('labels the two known ops', () => {
    expect(mailboxOpLabel('draft_append')).toBe('Draft in your mail app');
    expect(mailboxOpLabel('archive_source')).toBe('Original filed to AI/Processed');
  });

  it('falls back to the raw name for an unknown op', () => {
    expect(mailboxOpLabel('mystery_op')).toBe('mystery_op');
  });
});

describe('mailboxOpChip', () => {
  it('maps done to act, failed to warn, everything else to neutral', () => {
    expect(mailboxOpChip('done')).toBe('act');
    expect(mailboxOpChip('failed')).toBe('warn');
    expect(mailboxOpChip('pending')).toBe('neutral');
    expect(mailboxOpChip('skipped')).toBe('neutral');
    expect(mailboxOpChip('unsupported')).toBe('neutral');
    expect(mailboxOpChip('unknown_future_status')).toBe('neutral');
  });
});

describe('mailboxOpStatusText', () => {
  it('maps every known status', () => {
    expect(mailboxOpStatusText('pending')).toBe('Pending');
    expect(mailboxOpStatusText('done')).toBe('Done');
    expect(mailboxOpStatusText('failed')).toBe('Failed');
    expect(mailboxOpStatusText('skipped')).toBe('Not needed (sample message)');
    expect(mailboxOpStatusText('unsupported')).toBe(
      "Needs a manual move — your mail server doesn't support automatic moves"
    );
  });

  it('falls back to the raw status for an unrecognized value', () => {
    expect(mailboxOpStatusText('mystery')).toBe('mystery');
  });
});

describe('mailboxOpRows', () => {
  it('orders draft_append before archive_source regardless of key order', () => {
    const rows = mailboxOpRows({
      archive_source: { status: 'pending' },
      draft_append: { status: 'done' }
    });
    expect(rows.map((r) => r.name)).toEqual(['draft_append', 'archive_source']);
  });

  it('omits an op that is not present at all (a reject/2 envelope has no draft_append)', () => {
    const rows = mailboxOpRows({ archive_source: { status: 'pending' } });
    expect(rows.map((r) => r.name)).toEqual(['archive_source']);
  });

  it('returns an empty list for null/non-map input (a non-email_draft decided item)', () => {
    expect(mailboxOpRows(null)).toEqual([]);
    expect(mailboxOpRows('nope')).toEqual([]);
  });

  it('surfaces the error as a hint for failed and unsupported, never for done/pending/skipped', () => {
    const rows = mailboxOpRows({
      draft_append: { status: 'failed', error: 'imap timeout' },
      archive_source: { status: 'unsupported', error: 'no MOVE/UIDPLUS' }
    });
    expect(rows[0]).toMatchObject({ status: 'failed', hint: 'imap timeout', canRetry: true, chip: 'warn' });
    expect(rows[1]).toMatchObject({ status: 'unsupported', hint: 'no MOVE/UIDPLUS', canRetry: false, chip: 'neutral' });
  });

  it('only marks failed rows as retryable', () => {
    const rows = mailboxOpRows({
      draft_append: { status: 'done' },
      archive_source: { status: 'failed', error: 'x' }
    });
    expect(rows.find((r) => r.name === 'draft_append')?.canRetry).toBe(false);
    expect(rows.find((r) => r.name === 'archive_source')?.canRetry).toBe(true);
  });
});

describe('retryMailboxOpsErrorMessage', () => {
  it('maps every known error code', () => {
    expect(retryMailboxOpsErrorMessage('workspace_not_open')).toBe('No workspace is open.');
    expect(retryMailboxOpsErrorMessage('inactive')).toBe('No workspace is open.');
    expect(retryMailboxOpsErrorMessage('workspace_changed')).toBe('Your workspace changed. Reopen it and try again.');
    expect(retryMailboxOpsErrorMessage('not_configured')).toBe('Connect your mailbox first.');
    expect(retryMailboxOpsErrorMessage('no_credential')).toBe('Enter your mailbox password first.');
  });

  it('falls back to a generic message for an unknown code', () => {
    expect(retryMailboxOpsErrorMessage('mystery')).toBe('Could not retry. Please try again.');
  });
});
