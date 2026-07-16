import { describe, it, expect } from 'vitest';
import {
  sentence,
  auditDot,
  transcriptHref,
  formatAuditTimestamp,
  auditIcmName,
  type AuditIcmDirectoryEntry
} from './sentence';
import type { AuditEntry } from '$lib/api/client';

function entry(type: string, fields: Record<string, unknown> = {}): AuditEntry {
  return { ts: '2026-07-10T12:00:00Z', type, generation: 1, ...fields };
}

describe('sentence', () => {
  it('permission_auto_allowed: quotes the tool-call title', () => {
    expect(
      sentence(
        entry('permission_auto_allowed', { item_id: 'p1', title: 'Read Offers/Founder Coaching.md', kind: 'allow_once' })
      )
    ).toBe('Allowed automatically: Read Offers/Founder Coaching.md.');
  });

  it('permission_auto_denied: quotes the tool-call title', () => {
    expect(sentence(entry('permission_auto_denied', { item_id: 'p1', title: 'Delete staging/x.json' }))).toBe(
      'Denied automatically: Delete staging/x.json.'
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

  it('unknown type: humanizes the type string instead of crashing', () => {
    expect(sentence(entry('session_exited', { code: 0 }))).toBe('Session exited.');
  });

  it('unknown type with an empty/missing type never crashes', () => {
    expect(sentence(entry(''))).toBe('Unrecognized event.');
  });

  it('never throws on a bare-minimum entry (only ts/type/generation)', () => {
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

  it('falls back to ink for anything unrecognized', () => {
    expect(auditDot('session_exited')).toBe('ink');
    expect(auditDot('')).toBe('ink');
  });
});

describe('transcriptHref', () => {
  it('links to /chat?session=<id> when session_id is present', () => {
    expect(transcriptHref(entry('session_exited', { session_id: 'sess-1' }))).toBe('/chat?session=sess-1');
  });

  it('returns null when session_id is absent', () => {
    expect(transcriptHref(entry('session_exited'))).toBeNull();
  });
});

describe('auditIcmName', () => {
  const mounts: AuditIcmDirectoryEntry[] = [
    { id: 'icm-1', mountKey: 'primary', name: 'Mara Lindt Coaching' },
    { id: null, mountKey: 'degraded-one', name: 'Degraded' }
  ];

  it('resolves icm_mounted/icm_unmounted by mount_key directly', () => {
    expect(auditIcmName(entry('icm_mounted', { mount_key: 'primary', path: '/x', id: 'icm-1' }), mounts)).toBe(
      'Mara Lindt Coaching'
    );
    expect(auditIcmName(entry('icm_unmounted', { mount_key: 'primary', path: '/x' }), mounts)).toBe(
      'Mara Lindt Coaching'
    );
  });

  it('returns null when the named ICM is no longer in the directory (unmounted since)', () => {
    expect(auditIcmName(entry('icm_unmounted', { mount_key: 'gone', path: '/x' }), mounts)).toBeNull();
  });

  it('returns null for entry types that name no ICM at all (permission_*, session_exited, ...)', () => {
    expect(auditIcmName(entry('permission_asked', { item_id: 'p1', title: 'Write x' }), mounts)).toBeNull();
    expect(auditIcmName(entry('session_exited', { code: 0 }), mounts)).toBeNull();
  });

  it('never throws on a bare-minimum entry or an empty directory', () => {
    expect(() => auditIcmName({ ts: '', type: 'session_exited', generation: null }, [])).not.toThrow();
    expect(auditIcmName(entry('icm_mounted', { mount_key: 'primary' }), [])).toBeNull();
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
