import { describe, it, expect } from 'vitest';
import { normalizeIcmPage } from './client';

describe('normalizeIcmPage', () => {
  it('passes frontmatter through untouched, including its own snake_case keys', () => {
    const raw = {
      path: 'Workflows/Contract.md',
      title: 'Contract',
      uri: 'icm://Workflows/Contract.md',
      content: '---\nenabled: true\nrisk_level: medium\n---\n# Contract',
      hash: 'abc123',
      prosemirror: { type: 'doc', content: [] },
      frontmatter: {
        enabled: true,
        risk_level: 'medium',
        trigger: { type: 'manual', source: 'email.selected' },
        sources: [{ id: 'a' }, { id: 'b' }]
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
      path: 'Workflows/Broken.md',
      title: 'Broken',
      uri: 'icm://Workflows/Broken.md',
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
