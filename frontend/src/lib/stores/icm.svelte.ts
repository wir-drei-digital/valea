import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';
import { wireQueueEvents } from './queue.svelte';
import { wireAuditEvents } from './audit.svelte';
import { wireMailEvents } from './mail.svelte';
import { wireMountsEvents } from './mounts.svelte';
import { workflowsStore } from './workflows.svelte';

type IcmApi = Pick<Api, 'icmTree'>;

/**
 * One entry of the grouped `icm_tree` RPC (A-T11) — one per enabled mount.
 * `mount` is the mount's stable name (`Valea.Mounts`'s `name`), `title`/
 * `rootRel` mirror `MountSummary`'s `title`/`relRoot` (named `rootRel` here
 * to match the `icm_tree` action's own field name — see `IcmTreeFields` in
 * `api/ash_rpc.ts` — a naming difference from `list_mounts`'s `relRoot`
 * that's a generated-type fact, not a typo). `tree` is that mount's
 * ICM tree, already normalized to `IcmNode[]` the same way the old flat
 * `nodes` array was.
 */
export type MountGroup = {
  mount: string;
  title: string;
  rootRel: string;
  tree: IcmNode[];
};

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
  if (raw.type === 'folder') {
    const pageCount = typeof raw.page_count === 'number'
      ? raw.page_count
      : (typeof raw.pageCount === 'number' ? raw.pageCount : 0);

    return {
      name: raw.name,
      path: raw.path,
      type: 'folder',
      children: Array.isArray(raw.children) ? raw.children.map(normalizeIcmNode) : [],
      pageCount
    };
  }

  // A-T15 fix wave: non-.md file leaves keep their type (and `ext`, already
  // lowercase from the backend) instead of being coerced to 'page' — a
  // coerced file would render as an openable page and 404 in the editor.
  if (raw.type === 'file') {
    return {
      name: raw.name,
      path: raw.path,
      type: 'file',
      ext: typeof raw.ext === 'string' ? raw.ext : ''
    };
  }

  // Anything else (including an unknown future type) still defaults to
  // 'page' — the pre-existing defensive posture, unchanged.
  return {
    name: raw.name,
    path: raw.path,
    type: 'page',
    uri: raw.uri
  };
}

function normalizeNode(raw: Record<string, any>): IcmNode {
  return normalizeIcmNode(raw);
}

export class IcmStore {
  /**
   * Grouped ICM tree (A-T11) — one `MountGroup` per enabled mount, in the
   * order the backend reports them. This is the real, current shape of
   * `icm_tree`'s result; `nodes` below is a back-compat shim over it.
   */
  groups: MountGroup[] = $state([]);
  /**
   * True once the first `refetch()` call has resolved successfully.
   * `groups` starts empty and stays empty until the async refetch resolves
   * (SSR is off, so this is the default state on a cold/direct/refreshed
   * load), so callers must not treat an empty tree as "path not found"
   * until this flips true — otherwise pages that exist flash a false
   * not-found while the tree is still loading.
   */
  loaded = $state(false);

  #api: IcmApi;

  constructor(api: IcmApi) {
    this.#api = api;
  }

  async refetch(): Promise<void> {
    const result = await this.#api.icmTree();
    if (!result.ok) return;

    const data = result.data as {
      mounts?: Array<{ mount: string; title: string; rootRel: string; tree?: Record<string, any>[] }>;
    };
    this.groups = (data.mounts ?? []).map((g) => ({
      mount: g.mount,
      title: g.title,
      rootRel: g.rootRel,
      tree: (g.tree ?? []).map(normalizeNode)
    }));
    this.loaded = true;
  }

  /**
   * Clears the tree back to its cold-start shape. Called on every
   * workspace-change push so a stale tree from the previous workspace can
   * never be mistaken for the new one's — see `wireIcmEvents` below.
   */
  reset(): void {
    this.groups = [];
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
 *
 * CARRY-FORWARD (T20): `workflowsStore.refetch()` is called directly from
 * `onIcmChanged` below, alongside `icmStore.refetch()` — workflow
 * definitions live under `icm/Workflows/*.md` (see `WorkflowsStore`'s doc
 * comment in `workflows.svelte.ts`), so any `icm_changed` push that
 * invalidates the ICM tree invalidates the workflow catalog too. Also wires
 * `wireAuditEvents` onto the same shared channel, same reasoning as
 * `wireQueueEvents` above: the audit trail grows on every queue mutation,
 * so it rides `queue_changed` on this one join rather than opening a
 * second.
 *
 * CARRY-FORWARD (T16 — `/mail` route): also wires `wireMailEvents` onto the
 * same shared channel, same reasoning again — `mail_status`/`mail_sync`/
 * `mail_message`/`mailbox_ops` all ride this one `workspace:events` join
 * rather than the `/mail` route opening its own (see `wireMailEvents`'s doc
 * comment in `mail.svelte.ts` for why a route-local join would race this
 * one). `mailStore` stays live in the background exactly like `queueStore`/
 * `auditStore` already do, not only while `/mail` is mounted.
 *
 * CARRY-FORWARD (A-T14): also wires `wireMountsEvents` onto the same shared
 * channel, same reasoning again — `mounts_changed` (A-T6/A-T12: a mount
 * manifest change on disk, or an RPC-driven enable/disable/create) rides
 * this one `workspace:events` join too. `wireMountsEvents` itself drives
 * both `mountsStore.refresh()` AND `icmStore.refetch()` (see
 * `MountsStore.handleMountsChanged`'s doc comment in `mounts.svelte.ts`) —
 * a mount toggling changes `icm_tree`'s grouping (A-T11), not just
 * `list_mounts`'s output, so the two stores go stale together.
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
      void workflowsStore.refetch();
    }
  });

  wireQueueEvents(channel);
  wireAuditEvents(channel);
  wireMailEvents(channel);
  wireMountsEvents(channel);
}
