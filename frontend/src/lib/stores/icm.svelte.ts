import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';
import { wireQueueEvents } from './queue.svelte';

type IcmApi = Pick<Api, 'icmTree'>;

/**
 * Normalizes a raw RPC tree node into `IcmNode`. The backend returns plain
 * :map objects that bypass ash_typescript's camelCase formatter, so fields
 * arrive snake_case (e.g., `page_count`, not `pageCount`). This function
 * handles both formats for robustness while mapping to the canonical
 * camelCase `IcmNode` structure. Folder/page distinction already line up,
 * but this keeps the mapping explicit and defends against `Record<string, any>`
 * typing (`InferIcmTreeResult`) drifting from the shape at runtime.
 */
export function normalizeIcmNode(raw: Record<string, any>): IcmNode {
  const type: IcmNode['type'] = raw.type === 'folder' ? 'folder' : 'page';

  if (type === 'folder') {
    const pageCount = typeof raw.page_count === 'number'
      ? raw.page_count
      : (typeof raw.pageCount === 'number' ? raw.pageCount : 0);

    return {
      name: raw.name,
      path: raw.path,
      type,
      children: Array.isArray(raw.children) ? raw.children.map(normalizeIcmNode) : [],
      pageCount
    };
  }

  return {
    name: raw.name,
    path: raw.path,
    type,
    uri: raw.uri
  };
}

function normalizeNode(raw: Record<string, any>): IcmNode {
  return normalizeIcmNode(raw);
}

export class IcmStore {
  nodes: IcmNode[] = $state([]);
  /**
   * True once the first `refetch()` call has resolved successfully. `nodes`
   * starts empty and stays empty until the async refetch resolves (SSR is
   * off, so this is the default state on a cold/direct/refreshed load), so
   * callers must not treat an empty `nodes` as "path not found" until this
   * flips true — otherwise pages that exist flash a false not-found while
   * the tree is still loading.
   */
  loaded = $state(false);

  #api: IcmApi;

  constructor(api: IcmApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.icmTree();
    if (!result.ok) return;

    const data = result.data as { nodes?: Record<string, any>[] };
    this.nodes = (data.nodes ?? []).map(normalizeNode);
    this.loaded = true;
  }

  /**
   * Clears the tree back to its cold-start shape. Called on every
   * workspace-change push so a stale tree from the previous workspace can
   * never be mistaken for the new one's — see `wireIcmEvents` below.
   */
  reset(): void {
    this.nodes = [];
    this.loaded = false;
  }
}

export const icmStore = new IcmStore(api);

let icmEventsWired = false;

/**
 * Joins `workspace:events` and keeps the tree fresh when the backend reports
 * icm/ changes on disk. Explicit (not import-time) so that merely importing
 * this module never opens a socket as a side effect; idempotent so repeated
 * calls are safe.
 *
 * SINGLE CALL SITE: this is wired from the root layout (`src/routes/+layout.svelte`)
 * only. `onWorkspace` is an optional pass-through so the root layout can wire
 * its own workspace open/close handling through this SAME join rather than
 * opening a second one. Phoenix's JS client tags every push with the
 * joining channel's `join_ref` and only delivers it to the client-side
 * `Channel` object with a matching ref (see
 * `phoenix/assets/js/phoenix/channel.js#isMember`) — two independent
 * `socket.channel('workspace:events', {})` joins to the same topic race,
 * and only one reliably receives pushes. One join, wired here, avoids that.
 * Because of that constraint, a second call site passing its own
 * `onWorkspace` would have that handler silently dropped (see below) — if a
 * future call site genuinely needs a different `onWorkspace` handler, this
 * function needs to grow support for multiple subscribers instead of being
 * called again.
 *
 * CARRY-FORWARD (T19): also wires `wireQueueEvents` onto the SAME channel
 * this join returns, right here — not a second call site. `wireQueueEvents`
 * takes an already-joined channel rather than joining its own for exactly
 * this reason (see its doc comment in `queue.svelte.ts`): a second
 * independent `workspace:events` join races this one and only one
 * reliably receives pushes, so `queue_changed` has to ride the same join
 * `icm_changed` does.
 */
export function wireIcmEvents(onWorkspace?: (payload: WorkspaceEventPayload) => void): void {
  if (icmEventsWired) {
    if (onWorkspace) {
      console.warn('[icm] wireIcmEvents already wired; additional onWorkspace handler ignored');
    }
    return;
  }
  icmEventsWired = true;

  const channel = joinWorkspaceEvents({
    onWorkspace: (payload) => {
      // The store owns its own coherence: on every workspace change
      // (close, open, or switch), the previous workspace's tree is no
      // longer valid, so drop it before anything else runs. When the new
      // workspace is open, immediately refetch so `loaded` reflects the
      // NEW tree rather than sitting on the stale one. This must happen
      // before the external `onWorkspace` callback so downstream
      // consumers (e.g. route guards reacting to `workspaceStore`) never
      // observe a `loaded: true` tree that belongs to the old workspace.
      icmStore.reset();
      if (payload.open) {
        void icmStore.refetch();
      }
      onWorkspace?.(payload);
    },
    onIcmChanged: () => {
      void icmStore.refetch();
    }
  });

  wireQueueEvents(channel);
}
