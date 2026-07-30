import { describe, it, expect } from 'vitest';
import { getMailAccountSettingsFields, normalizeIcmPage } from './client';

describe('normalizeIcmPage', () => {
  it('passes frontmatter through untouched, including its own snake_case keys', () => {
    const raw = {
      path: 'Notes/Contract.md',
      title: 'Contract',
      uri: 'icm://Notes/Contract.md',
      content: '---\nstatus: active\nreview_date: 2026-08-01\n---\n# Contract',
      hash: 'abc123',
      prosemirror: { type: 'doc', content: [] },
      frontmatter: {
        status: 'active',
        review_date: '2026-08-01',
        owner: { name: 'Dana', email: 'dana@example.com' },
        tags: ['a', 'b']
      }
    };

    const result = normalizeIcmPage(raw);

    // Every frontmatter key stays exactly as authored — no camelCase pass,
    // no key renaming, no reshaping of nested structure.
    expect(result.frontmatter).toEqual(raw.frontmatter);
    expect(result.frontmatter).toStrictEqual(raw.frontmatter);
  });

  it('defaults frontmatter to null when absent', () => {
    const raw = {
      path: 'Offers/Founder Coaching Package.md',
      title: 'Founder Coaching Package',
      uri: 'icm://Offers/Founder Coaching Package.md',
      content: '# Founder Coaching Package',
      hash: 'def456',
      prosemirror: { type: 'doc', content: [] }
    };

    const result = normalizeIcmPage(raw);

    expect(result.frontmatter).toBeNull();
  });

  it('preserves frontmatter: null (malformed YAML on the backend) rather than substituting a default', () => {
    const raw = {
      path: 'Notes/Broken.md',
      title: 'Broken',
      uri: 'icm://Notes/Broken.md',
      content: '---\n{ broken\n---\n# X',
      hash: 'ghi789',
      prosemirror: { type: 'doc', content: [] },
      frontmatter: null
    };

    const result = normalizeIcmPage(raw);

    expect(result.frontmatter).toBeNull();
  });

  it('passes through the plain top-level fields unchanged', () => {
    const raw = {
      path: 'Offers/Founder Coaching Package.md',
      title: 'Founder Coaching Package',
      uri: 'icm://Offers/Founder Coaching Package.md',
      content: '# Founder Coaching Package',
      hash: 'def456',
      prosemirror: { type: 'doc', content: [{ type: 'paragraph' }] },
      frontmatter: null
    };

    const result = normalizeIcmPage(raw);

    expect(result).toEqual(raw);
  });
});

// The field selection is the whole reason the edit form can round-trip an
// oauth2 account. `setup_mail_account` re-renders the account entry WHOLE, so
// a field the prefill never read is a field the save silently rewrites:
// dropping `auth` downgrades the account to `password` (and the engine then
// offers its OAuth2 access token as a LOGIN password), and dropping
// `oauthClientId` discards the user's client-id override. Nothing else fails
// when either goes — the setup suite hands `auth` in directly and the
// component reads the prefill through an unchecked cast — so this is the pin.
describe('getMailAccountSettingsFields', () => {
  const accountBlock = (): unknown[] => {
    const entries = getMailAccountSettingsFields as unknown as Array<string | Record<string, unknown[]>>;
    const block = entries.find((entry): entry is Record<string, unknown[]> => typeof entry === 'object' && entry !== null);
    expect(block, 'the selection has no nested `account:` block at all').toBeDefined();
    return block?.account ?? [];
  };

  it('selects auth inside the account block', () => {
    expect(accountBlock()).toContain('auth');
  });

  it('selects oauthClientId inside the account block', () => {
    expect(accountBlock()).toContain('oauthClientId');
  });
});
