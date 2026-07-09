import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { joinWorkspaceEvents } from '../socket';

type IcmApi = Pick<Api, 'icmTree'>;

/**
 * Normalizes a raw RPC tree node (camelCased by the backend's field
 * formatter, e.g. `page_count` -> `pageCount`) into `IcmNode`. Folder/page
 * distinction and field names already line up with `IcmNode`, but this keeps
 * the mapping explicit and defends against `Record<string, any>` typing
 * (`InferIcmTreeResult`) drifting from the shape at runtime.
 */
function normalizeNode(raw: Record<string, any>): IcmNode {
  const type: IcmNode['type'] = raw.type === 'folder' ? 'folder' : 'page';

  if (type === 'folder') {
    return {
      name: raw.name,
      path: raw.path,
      type,
      children: Array.isArray(raw.children) ? raw.children.map(normalizeNode) : [],
      pageCount: typeof raw.pageCount === 'number' ? raw.pageCount : 0
    };
  }

  return {
    name: raw.name,
    path: raw.path,
    type,
    uri: raw.uri
  };
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
 * Not called anywhere yet — the root layout wiring lands in task 18.
 */
export function wireIcmEvents(): void {
  if (icmEventsWired) return;
  icmEventsWired = true;

  joinWorkspaceEvents({
    onIcmChanged: () => {
      void icmStore.refetch();
    }
  });
}
