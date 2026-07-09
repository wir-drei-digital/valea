import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';

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

  #api: IcmApi;

  constructor(api: IcmApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.icmTree();
    if (!result.ok) return;

    const data = result.data as { nodes?: Record<string, any>[] };
    this.nodes = (data.nodes ?? []).map(normalizeNode);
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
 * `onWorkspace` is an optional pass-through so the root layout can wire its
 * own workspace open/close handling through this SAME join rather than
 * opening a second one. Phoenix's JS client tags every push with the
 * joining channel's `join_ref` and only delivers it to the client-side
 * `Channel` object with a matching ref (see
 * `phoenix/assets/js/phoenix/channel.js#isMember`) — two independent
 * `socket.channel('workspace:events', {})` joins to the same topic race,
 * and only one reliably receives pushes. One join, wired here, avoids that.
 */
export function wireIcmEvents(onWorkspace?: (payload: WorkspaceEventPayload) => void): void {
  if (icmEventsWired) return;
  icmEventsWired = true;

  joinWorkspaceEvents({
    onWorkspace,
    onIcmChanged: () => {
      void icmStore.refetch();
    }
  });
}
