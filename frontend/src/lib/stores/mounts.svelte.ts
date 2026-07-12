import { api, type Api } from '../api/client';
import { icmStore } from './icm.svelte';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as the other T16+ stores, so tests can inject a fake without
 * implementing every wrapped call.
 */
type MountsApi = Pick<Api, 'listMounts' | 'setMountEnabled' | 'createMount'>;

/**
 * One row of `list_mounts` — mirrors `listMountsFields` in `api/client.ts`.
 * `relRoot`/`enabled`/`degraded` are NESTED array-item fields on the
 * backend's typed `:map` action (see `Valea.Api.Mounts`'s moduledoc), so
 * unlike a top-level boolean-returning field, they arrive already
 * camelCased with no falsy-map-field workaround needed. `degraded` is
 * `null` for a healthy mount, a reason string otherwise (e.g.
 * `"manifest_missing"`).
 */
export type MountSummary = {
  name: string;
  title: string;
  description: string;
  relRoot: string;
  enabled: boolean;
  degraded: string | null;
};

/**
 * The mount catalog (`config/workspace.yaml`'s `mounts:` section, A-T1/A-T2)
 * — every mount the current workspace knows about, enabled or not. Powers
 * the (T15) mounts-management UI: toggling a mount, creating a new one, and
 * staying live as the backend reports `mounts_changed` pushes (A-T6, mount
 * manifest edits or an RPC mutation — see `Valea.Api.Mounts`'s moduledoc).
 */
export class MountsStore {
  mounts: MountSummary[] = $state([]);
  loaded = $state(false);

  #api: MountsApi;

  constructor(api: MountsApi) {
    this.#api = api;
  }

  async refresh(): Promise<void> {
    const result = await this.#api.listMounts();
    if (!result.ok) return;

    const data = result.data as { mounts?: MountSummary[] };
    this.mounts = data.mounts ?? [];
    this.loaded = true;
  }

  /**
   * Enables/disables a mount. `generation` is sourced from `workspaceStore`
   * by the caller (not injected) — same store-free-api convention
   * `api/client.ts`'s header comment documents; see `QueueStore.approve`
   * for the identical pattern. Refetches the catalog on success — the
   * disk-level change also arrives via `mounts_changed`
   * (`handleMountsChanged` below), but that push isn't guaranteed to beat
   * this refetch, and re-running it is harmless.
   */
  async setEnabled(
    name: string,
    enabled: boolean,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.setMountEnabled(name, enabled, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * Creates a new mount. Returns the backend-assigned `relRoot` (the
   * mount's directory, relative to the workspace root) so a caller (e.g.
   * T15's "new mount" dialog, or T16's onboarding adopt-by-move flow) can
   * navigate straight to it without a second round trip. Refetches the
   * catalog on success, same reasoning as `setEnabled`.
   */
  async create(
    name: string,
    description: string,
    generation: number
  ): Promise<{ ok: true; relRoot: string } | { ok: false; error: string }> {
    const result = await this.#api.createMount(name, description, generation);
    if (!result.ok) return { ok: false, error: result.error };

    const data = result.data as { relRoot: string };
    await this.refresh();
    return { ok: true, relRoot: data.relRoot };
  }

  /**
   * Handles a `mounts_changed` push (wired below via `wireMountsEvents`).
   * Refetches BOTH this store's own catalog and `icmStore`'s tree: a mount
   * being enabled/disabled/created changes not just `list_mounts`'s output
   * but also `icm_tree`'s grouping (A-T11 — a newly-enabled mount gains a
   * group, a disabled one loses one), so the two stores go stale together
   * and must refresh together. `icmStore` is imported directly rather than
   * injected — `icm.svelte.ts` imports `wireMountsEvents` back from this
   * module (to attach it alongside `wireQueueEvents`/`wireAuditEvents`/
   * `wireMailEvents` on the shared `workspace:events` join), so this pair
   * of modules is intentionally mutually-referencing; the cross-references
   * only ever run inside method bodies (never at module top-level
   * evaluation), which is safe under ES module circular resolution.
   */
  async handleMountsChanged(): Promise<void> {
    await this.refresh();
    await icmStore.refetch();
  }
}

export const mountsStore = new MountsStore(api);

let mountsEventsWired = false;

/**
 * Attaches a `mounts_changed` listener to an already-joined channel and
 * keeps `mountsStore` (and, via `handleMountsChanged`, `icmStore`) fresh.
 * Takes the channel as a parameter rather than joining its own — same
 * reason `wireQueueEvents`/`wireAuditEvents`/`wireMailEvents` do (see their
 * doc comments): Phoenix's JS client only reliably delivers pushes to ONE
 * join per topic per socket, so every store rides the single
 * `workspace:events` join `wireIcmEvents` (`icm.svelte.ts`) owns, rather
 * than opening a second one here.
 *
 * SINGLE CALL SITE: wired from `wireIcmEvents` itself, alongside
 * `wireQueueEvents`/`wireAuditEvents`/`wireMailEvents` — see that
 * function's doc comment in `icm.svelte.ts`.
 *
 * Idempotent against repeat calls, same spirit as `wireQueueEvents` — a
 * second call is a no-op rather than attaching a second `mounts_changed`
 * handler (which would double-refetch).
 */
export function wireMountsEvents(channel: Channel): void {
  if (mountsEventsWired) return;
  mountsEventsWired = true;

  channel.on('mounts_changed', () => {
    void mountsStore.handleMountsChanged();
  });
}
