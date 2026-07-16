import { api, type Api, type AuditEntry } from '../api/client';
import type { Channel } from 'phoenix';

/** Minimal surface of `api` this store depends on — same `Pick<Api, ...>` convention as the other T16+ stores. */
type AuditApi = Pick<Api, 'listAuditEntries'>;

/**
 * The audit receipts trail (`logs/audit.jsonl`, last 200 entries,
 * reverse-chron — `Valea.Audit.entries/1` already reverses before this
 * store ever sees it). Entries are heterogeneous by `type` and arrive raw
 * off the wire (see `AuditEntry`'s doc comment in `api/client.ts`), so this
 * store does no per-type normalization — `sentence()`
 * (`components/audit/sentence.ts`) is where entry shape gets interpreted.
 */
export class AuditStore {
  entries: AuditEntry[] = $state([]);
  loaded = $state(false);

  #api: AuditApi;

  constructor(api: AuditApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.listAuditEntries(200);
    if (!result.ok) return;

    const data = result.data as { entries?: AuditEntry[] };
    this.entries = data.entries ?? [];
    this.loaded = true;
  }
}

export const auditStore = new AuditStore(api);

let auditEventsWired = false;

/**
 * No-op placeholder kept for `wireIcmEvents`'s (`icm.svelte.ts`) shared-channel
 * wiring call site. Used to attach a `queue_changed` listener that kept
 * `auditStore` fresh live while any route was mounted — the queue/workflow
 * subsystem that emitted `queue_changed` is gone (Spec D deletion wave), and
 * dies on the backend in Task 2. `auditStore` now only refetches on route
 * load (`routes/audit/+page.svelte`'s `onMount`), which is sufficient since
 * there is no more live queue activity to reflect mid-session.
 */
export function wireAuditEvents(channel: Channel): void {
  if (auditEventsWired) return;
  auditEventsWired = true;
}
