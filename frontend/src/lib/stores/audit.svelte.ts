import { api, type Api, type AuditEntry } from '../api/client';

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
