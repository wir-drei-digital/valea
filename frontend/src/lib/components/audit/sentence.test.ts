import { describe, it, expect } from 'vitest';
import {
  sentence,
  auditDot,
  transcriptHref,
  reviewHref,
  formatAuditTimestamp
} from './sentence';
import type { AuditEntry } from '$lib/api/client';

function entry(type: string, fields: Record<string, unknown> = {}): AuditEntry {
  return { ts: '2026-07-10T12:00:00Z', type, generation: 1, ...fields };
}

describe('sentence', () => {
  it('workflow_run_started: names the workflow (basename, no .md) and the input', () => {
    expect(
      sentence(
        entry('workflow_run_started', {
          run_id: 'r1',
          workflow: 'icm/Workflows/New Inquiry Triage.md',
          input: 'sources/mail/normalized/priya.json'
        })
      )
    ).toBe('Started "New Inquiry Triage" on sources/mail/normalized/priya.json.');
  });

  it('workflow_run_started: falls back gracefully with no input', () => {
    expect(
      sentence(entry('workflow_run_started', { run_id: 'r1', workflow: 'icm/Workflows/X.md' }))
    ).toBe('Started "X".');
  });

  it.each([
    ['proposal_created', 'Workflow run finished — a proposal is waiting for review.'],
    ['no_proposal', 'Workflow run finished — no proposal was produced.'],
    ['invalid_proposal', "Workflow run finished — the proposal couldn't be read."],
    ['start_failed', 'Workflow run failed to start.'],
    ['something_new', 'Workflow run finished.']
  ])('workflow_run_finished outcome=%s', (outcome, expected) => {
    expect(sentence(entry('workflow_run_finished', { run_id: 'r1', outcome }))).toBe(expected);
  });

  it('queue_item_created: humanizes the kind', () => {
    expect(sentence(entry('queue_item_created', { run_id: 'r1', kind: 'email_draft' }))).toBe(
      'New proposal queued: email draft.'
    );
  });

  it('queue_item_created: falls back with no kind', () => {
    expect(sentence(entry('queue_item_created', { run_id: 'r1' }))).toBe('New proposal queued.');
  });

  it('permission_auto_allowed: quotes the tool-call title', () => {
    expect(
      sentence(
        entry('permission_auto_allowed', { item_id: 'p1', title: 'Read Offers/Founder Coaching.md', kind: 'allow_once' })
      )
    ).toBe('Allowed automatically: Read Offers/Founder Coaching.md.');
  });

  it('permission_auto_denied: quotes the tool-call title', () => {
    expect(sentence(entry('permission_auto_denied', { item_id: 'p1', title: 'Delete queue/pending' }))).toBe(
      'Denied automatically: Delete queue/pending.'
    );
  });

  it('permission_asked: quotes the tool-call title', () => {
    expect(sentence(entry('permission_asked', { item_id: 'p1', title: 'Write staging/x.json' }))).toBe(
      'Asked for permission: Write staging/x.json.'
    );
  });

  it('permission_answered: humanizes the answer kind', () => {
    expect(sentence(entry('permission_answered', { item_id: 'p1', kind: 'reject_once' }))).toBe(
      'You answered a permission request: reject once.'
    );
  });

  it('permission_answered: falls back with no kind', () => {
    expect(sentence(entry('permission_answered', { item_id: 'p1' }))).toBe(
      'You answered a permission request.'
    );
  });

  it('approval_intent', () => {
    expect(sentence(entry('approval_intent', { run_id: 'r1' }))).toBe(
      'Approval started — about to act on this proposal.'
    );
  });

  it('item_approved', () => {
    expect(sentence(entry('item_approved', { run_id: 'r1' }))).toBe(
      'You approved this proposal — draft created.'
    );
  });

  it('item_approved: recovered flag changes the sentence', () => {
    expect(sentence(entry('item_approved', { run_id: 'r1', recovered: true }))).toBe(
      'You approved this proposal after a restart — draft created.'
    );
  });

  it('item_rejected', () => {
    expect(sentence(entry('item_rejected', { run_id: 'r1' }))).toBe('You rejected this proposal.');
  });

  it('action_executed', () => {
    expect(sentence(entry('action_executed', { run_id: 'r1' }))).toBe('Draft created.');
  });

  it('approval_recovered', () => {
    expect(sentence(entry('approval_recovered', { run_id: 'r1' }))).toBe(
      'An interrupted approval was recovered — returned to pending for review.'
    );
  });

  it('unknown type: humanizes the type string instead of crashing', () => {
    expect(sentence(entry('session_exited', { code: 0 }))).toBe('Session exited.');
  });

  it('unknown type with an empty/missing type never crashes', () => {
    expect(sentence(entry(''))).toBe('Unrecognized event.');
  });

  it('never throws on a bare-minimum entry (only ts/type/generation)', () => {
    expect(() => sentence({ ts: '', type: 'workflow_run_started', generation: null })).not.toThrow();
    expect(() => sentence({ ts: '', type: 'permission_auto_allowed', generation: null })).not.toThrow();
    expect(() => sentence({ ts: '', type: 'totally_unknown_future_type', generation: null })).not.toThrow();
  });
});

describe('auditDot', () => {
  it('maps every permission_* type to amber', () => {
    expect(auditDot('permission_auto_allowed')).toBe('amber');
    expect(auditDot('permission_auto_denied')).toBe('amber');
    expect(auditDot('permission_asked')).toBe('amber');
    expect(auditDot('permission_answered')).toBe('amber');
  });

  it('maps item_approved and action_executed to green', () => {
    expect(auditDot('item_approved')).toBe('green');
    expect(auditDot('action_executed')).toBe('green');
  });

  it('maps item_rejected and workflow_run_* to ink (neutral)', () => {
    expect(auditDot('item_rejected')).toBe('ink');
    expect(auditDot('workflow_run_started')).toBe('ink');
    expect(auditDot('workflow_run_finished')).toBe('ink');
  });

  it('falls back to ink for anything unrecognized', () => {
    expect(auditDot('session_exited')).toBe('ink');
    expect(auditDot('')).toBe('ink');
  });
});

describe('transcriptHref', () => {
  it('links to /chat?session=<id> when session_id is present', () => {
    expect(transcriptHref(entry('workflow_run_started', { session_id: 'sess-1' }))).toBe(
      '/chat?session=sess-1'
    );
  });

  it('returns null when session_id is absent', () => {
    expect(transcriptHref(entry('item_approved', { run_id: 'r1' }))).toBeNull();
  });
});

describe('reviewHref', () => {
  it('links to /queue/<run_id> when run_id is present', () => {
    expect(reviewHref(entry('item_approved', { run_id: 'r1' }))).toBe('/queue/r1');
  });

  it('returns null when run_id is absent', () => {
    expect(reviewHref(entry('permission_asked', { item_id: 'p1' }))).toBeNull();
  });
});

describe('formatAuditTimestamp', () => {
  it('returns "" for an unparseable timestamp instead of "Invalid Date"', () => {
    expect(formatAuditTimestamp('not-a-date')).toBe('');
  });

  it('parses a valid ISO8601 timestamp', () => {
    expect(formatAuditTimestamp('2026-07-10T12:00:00Z')).not.toBe('');
  });
});
