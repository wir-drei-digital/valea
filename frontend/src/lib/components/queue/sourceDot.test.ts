import { describe, it, expect } from 'vitest';
import { sourceDot, sourceHref } from './sourceDot';

describe('sourceDot', () => {
  it('maps sources/mail/* to terracotta (email / external message)', () => {
    expect(sourceDot('sources/mail/normalized/priya-nair-inquiry.json')).toBe('terracotta');
  });

  it('maps icm/Clients/* to green (calendar / client memory)', () => {
    expect(sourceDot('icm/Clients/Lea Brunner.md')).toBe('green');
  });

  it('maps other icm/* paths to amber (policy / offer / document)', () => {
    expect(sourceDot('icm/Offers/Founder Coaching Package.md')).toBe('amber');
    expect(sourceDot('icm/Tone & Voice/Email Tone Guide.md')).toBe('amber');
    expect(sourceDot('icm/Policies/No Medical Advice.md')).toBe('amber');
  });

  it('falls back to amber for anything unrecognized', () => {
    expect(sourceDot('her email')).toBe('amber');
    expect(sourceDot('')).toBe('amber');
  });
});

describe('sourceHref', () => {
  it('links icm/*.md sources to their Knowledge page, icm/ prefix stripped and path-encoded', () => {
    // Knowledge routes are relative to the icm/ root itself (Valea.ICM.tree/0
    // computes `path` relative to `icm/`, not the workspace root) — a source
    // string like "icm/Offers/…" must drop that prefix to land on the same
    // URL `icmToNav` (frontend/src/lib/shell/nav.ts) builds for the sidebar.
    expect(sourceHref('icm/Offers/Founder Coaching Package.md')).toBe(
      '/knowledge/Offers/Founder%20Coaching%20Package.md'
    );
  });

  it('returns null for sources/mail/* — no raw viewer this phase', () => {
    expect(sourceHref('sources/mail/normalized/priya-nair-inquiry.json')).toBeNull();
  });

  it('returns null for non-.md icm paths and free-text sources', () => {
    expect(sourceHref('icm/Clients')).toBeNull();
    expect(sourceHref('her email')).toBeNull();
  });
});
