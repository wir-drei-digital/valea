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
 * Attaches a `queue_changed` listener to an already-joined channel and keeps
 * `auditStore` fresh — every queue mutation (approve/reject/new proposal)
 * writes an audit entry, so the same push that refreshes `queueStore`
 * (`wireQueueEvents`, `queue.svelte.ts`) also means the audit trail grew.
 * Takes the channel as a parameter rather than joining its own, same reason
 * `wireQueueEvents` does (see its doc comment and `wireIcmEvents` in
 * `icm.svelte.ts`): a second independent `workspace:events` join races the
 * shared one and only one reliably receives pushes.
 *
 * Idempotent against repeat calls, same spirit as `wireQueueEvents` — a
 * second call is a no-op rather than attaching a second `queue_changed`
 * handler (which would double-refetch).
 */
export function wireAuditEvents(channel: Channel): void {
  if (auditEventsWired) return;
  auditEventsWired = true;

  channel.on('queue_changed', () => {
    void auditStore.refetch();
  });
}
