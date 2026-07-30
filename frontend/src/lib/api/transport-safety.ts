import type { ApiResult } from './client';

/**
 * Makes the "every RPC settles to an `ApiResult`" contract total (issue #2
 * hardening). The channel path already synthesizes envelopes for timeouts
 * and error replies (`wrapChannelCall`), and the generated HTTP path wraps
 * non-ok responses — but a REJECTED fetch (connection refused, DNS failure)
 * throws past all of that. Un-caught, it rejects `refetch`/
 * `ensurePathLoaded`/`loadPage` in turn, so no store error state can observe
 * the failure and the UI sits on its loading state forever. Normalized here
 * to the same `network_error` the HTTP path already uses for non-ok
 * responses.
 */
export async function settleApiResult<T>(promise: Promise<ApiResult<T>>): Promise<ApiResult<T>> {
  try {
    return await promise;
  } catch (e) {
    console.warn('[api] rpc transport rejected; normalizing to network_error', e);
    return { ok: false, error: 'network_error' };
  }
}
