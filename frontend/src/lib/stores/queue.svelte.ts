import { api, type Api } from '../api/client';
import { workspaceStore } from './workspace.svelte';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as `workspace.svelte.ts`/`page-editor.svelte.ts`, so tests can
 * inject a fake without implementing every wrapped call.
 */
type QueueApi = Pick<Api, 'listQueueItems' | 'getQueueItem' | 'approveQueueItem' | 'rejectQueueItem'>;

/** One row of `list_queue_items` — mirrors `listQueueItemsFields` in `api/client.ts`. */
export type QueueListItem = {
  runId: string;
  title: string;
  summary: string;
  kind: string;
  riskLevel: string;
  createdAt: string;
  workflow: string;
  valid: boolean;
  error?: string | null;
};

export class QueueStore {
  items: QueueListItem[] = $state([]);
  loaded = $state(false);

  #api: QueueApi;

  constructor(api: QueueApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.listQueueItems();
    if (!result.ok) return;

    const data = result.data as { items?: QueueListItem[] };
    this.items = data.items ?? [];
    this.loaded = true;
  }

  /** Full envelope + revision for one pending item — passed straight through from `api.getQueueItem`. */
  detail(runId: string) {
    return this.#api.getQueueItem(runId);
  }

  /**
   * Approves a pending item. `generation` is sourced from `workspaceStore`
   * (not injected) — same convention `api/client.ts`'s header comment
   * documents: the API layer stays store-free, so the T16+ stores are
   * responsible for sourcing generation from the open workspace and passing
   * it in. Refetches the list on success (mirrors `WorkspaceStore.create`/
   * `.open` refreshing derived state after a successful mutation) — the
   * disk-level change will also arrive via `queue_changed` (see
   * `wireQueueEvents` below), but that push is not guaranteed to beat this
   * refetch, and re-running it is harmless.
   */
  async approve(runId: string, revision: string): Promise<{ ok: true } | { ok: false; error: string }> {
    const generation = workspaceStore.generation ?? 0;
    const result = await this.#api.approveQueueItem(runId, revision, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refetch();
    return { ok: true };
  }

  /** Rejects a pending item. Same generation-sourcing and refetch-on-success as `approve`. */
  async reject(runId: string, revision: string): Promise<{ ok: true } | { ok: false; error: string }> {
    const generation = workspaceStore.generation ?? 0;
    const result = await this.#api.rejectQueueItem(runId, revision, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refetch();
    return { ok: true };
  }
}

export const queueStore = new QueueStore(api);

let queueEventsWired = false;

/**
 * Attaches a `queue_changed` listener to an already-joined channel and keeps
 * `queueStore` fresh when the backend reports queue/ changes on disk (see
 * `Valea.ICM.Watcher`, which broadcasts `queue_changed` on the same
 * `workspace:events` topic `icm_changed` rides). Takes the channel as a
 * parameter (rather than joining its own, the way `wireIcmEvents` does)
 * because Phoenix's JS client only reliably delivers pushes to ONE join per
 * topic per socket (see `wireIcmEvents`'s doc in `icm.svelte.ts` for the
 * concrete failure mode) — the caller is expected to pass the single shared
 * `workspace:events` channel (e.g. the one `joinWorkspaceEvents`/
 * `wireIcmEvents` already joined), not open a second one.
 *
 * Idempotent against repeat calls with the SAME already-wired state, same
 * spirit as `wireIcmEvents` — a second call is a no-op rather than
 * attaching a second `queue_changed` handler (which would double-refetch).
 */
export function wireQueueEvents(channel: Channel): void {
  if (queueEventsWired) return;
  queueEventsWired = true;

  channel.on('queue_changed', () => {
    void queueStore.refetch();
  });
}
