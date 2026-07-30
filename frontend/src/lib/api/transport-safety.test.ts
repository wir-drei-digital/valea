import { describe, it, expect, vi, afterEach } from 'vitest';
import { settleApiResult } from './transport-safety';

// Issue #2 hardening: every RPC failure is supposed to RESOLVE to a non-ok
// envelope (`wrapChannelCall` synthesizes timeouts, the generated HTTP path
// wraps non-ok responses) — but a REJECTED fetch (connection refused, DNS)
// used to throw straight through `runRpc`, so no store error state could ever
// observe it: `refetch`/`ensurePathLoaded` rejected and the UI sat on a
// skeleton forever. This wrapper makes the "always resolves" contract total.
describe('settleApiResult', () => {
  afterEach(() => vi.restoreAllMocks());

  it('passes a resolved ok result through untouched', async () => {
    await expect(settleApiResult(Promise.resolve({ ok: true, data: { x: 1 } }))).resolves.toEqual({
      ok: true,
      data: { x: 1 }
    });
  });

  it('passes a resolved non-ok result through untouched', async () => {
    await expect(settleApiResult(Promise.resolve({ ok: false, error: 'not_found' }))).resolves.toEqual({
      ok: false,
      error: 'not_found'
    });
  });

  it('normalizes a rejected transport into a non-ok network_error result instead of throwing', async () => {
    vi.spyOn(console, 'warn').mockImplementation(() => {});

    await expect(settleApiResult(Promise.reject(new TypeError('Failed to fetch')))).resolves.toEqual({
      ok: false,
      error: 'network_error'
    });
  });
});
