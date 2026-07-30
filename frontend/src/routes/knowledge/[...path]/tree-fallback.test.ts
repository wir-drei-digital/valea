import { describe, it, expect } from 'vitest';
import { treeFallback } from './tree-fallback';

// Issue #2 (github): the main pane rendered "This page doesn't exist anymore."
// for ANY tree problem — a failed mount list even left the loading skeleton up
// forever. These pin the decision table: 'missing' may only come from a
// DEFINITIVE ensure answer; every failure path must land on 'unavailable'
// (load failed + retry), never on a false non-existence claim.
describe('treeFallback', () => {
  it('shows the skeleton while the ensure walk is still running and nothing has failed', () => {
    expect(treeFallback({ ensureStatus: null, listError: null, mountError: undefined })).toBe('loading');
  });

  it('claims non-existence ONLY on a definitive ensure miss', () => {
    expect(treeFallback({ ensureStatus: 'missing', listError: null, mountError: undefined })).toBe('missing');
  });

  it('reports unavailable when the ensure walk hit a failed listing', () => {
    expect(treeFallback({ ensureStatus: 'unavailable', listError: null, mountError: undefined })).toBe(
      'unavailable'
    );
  });

  it('reports unavailable (not an eternal skeleton) when the mount list failed before ensure settled', () => {
    expect(treeFallback({ ensureStatus: null, listError: 'channel_timeout', mountError: undefined })).toBe(
      'unavailable'
    );
  });

  it("reports unavailable when this mount's root listing failed before ensure settled", () => {
    expect(treeFallback({ ensureStatus: null, listError: null, mountError: 'channel_timeout' })).toBe(
      'unavailable'
    );
  });

  it('a definitive miss wins over a stale store-level error — the parent listing succeeded', () => {
    expect(treeFallback({ ensureStatus: 'missing', listError: 'channel_timeout', mountError: undefined })).toBe(
      'missing'
    );
  });

  it("a found node needs no fallback — store-level errors don't turn it into one", () => {
    expect(treeFallback({ ensureStatus: 'found', listError: 'channel_timeout', mountError: undefined })).toBe(
      'loading'
    );
  });
});
