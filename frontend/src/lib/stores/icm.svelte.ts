import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { workspaceStore } from './workspace.svelte';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';
import { wireQueueEvents } from './queue.svelte';
import { wireAuditEvents } from './audit.svelte';
import { wireMailEvents } from './mail.svelte';
import { wireMountsEvents } from './mounts.svelte';
import { workflowsStore } from './workflows.svelte';
import { recentSessionsStore, wireRecentSessionsEvents } from './recent-sessions.svelte';

type IcmApi = Pick<Api, 'icmTree' | 'listIcms'>;

/** Minimal shape this store needs from `list_icms` — see `MountSummary` in `stores/mounts.svelte.ts` for the full row. */
type IcmListRow = { mountKey: string; enabled: boolean; degraded: string | null };

/**
 * One ICM's tree (task 4.2/4.3 re-key) — `mount` is the mount's stable key
 * (`Valea.Mounts`'s `name`), `title` its display name. `tree` is that
 * mount's ICM tree, already normalized to `IcmNode[]` — every node stamped
 * with `mountKey` (see `normalizeIcmNode`) so it stays self-describing once
 * flattened across mounts (`flattenMountGroups`, `lib/shell/nav.ts`).
 *
 * `rootRel` (A-T11) is gone: `icm_tree` is now single-ICM (`Valea.Api.ICM`'s
 * `:tree` action takes `mountKey` + `generation`), and "the mount's own
 * root" is simply `""` in the new ICM-relative addressing — no separate
 * field needed to name it.
 */
export type MountGroup = {
  mount: string;
  title: string;
  tree: IcmNode[];
};

/**
 * Normalizes a raw RPC tree node into `IcmNode`, stamping `mountKey` onto
 * every node (including nested children) — the backend returns plain :map
 * objects that bypass ash_typescript's camelCase formatter, so fields
 * arrive snake_case (e.g., `page_count`, not `pageCount`). This function
 * handles both formats for robustness while mapping to the canonical
 * camelCase `IcmNode` structure. Folder/page distinction already line up,
 * but this keeps the mapping explicit and defends against `Record<string, any>`
 * typing (`InferIcmTreeResult`) drifting from the shape at runtime.
 */
export function normalizeIcmNode(raw: Record<string, any>, mountKey: string): IcmNode {
  if (raw.type === 'folder') {
    const pageCount = typeof raw.page_count === 'number'
      ? raw.page_count
      : (typeof raw.pageCount === 'number' ? raw.pageCount : 0);

    return {
      name: raw.name,
      path: raw.path,
      mountKey,
      type: 'folder',
      children: Array.isArray(raw.children) ? raw.children.map((c: Record<string, any>) => normalizeIcmNode(c, mountKey)) : [],
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
      mountKey,
      type: 'file',
      ext: typeof raw.ext === 'string' ? raw.ext : ''
    };
  }

  // Anything else (including an unknown future type) still defaults to
  // 'page' — the pre-existing defensive posture, unchanged.
  return {
    name: raw.name,
    path: raw.path,
    mountKey,
    type: 'page',
    uri: raw.uri
  };
}

export class IcmStore {
  /**
   * One `MountGroup` per ENABLED, non-degraded mount, in `list_icms`'s
   * order. `icm_tree` (task 4.2 re-key) is now single-ICM, so `refetch`
   * fans out: it lists the mount catalog, then fetches each enabled mount's
   * tree in parallel and assembles the same grouped shape this store
   * always exposed — every other consumer (`mount-sections.ts`, the
   * Knowledge routes) is unaffected by the RPC split underneath.
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
    const generation = workspaceStore.generation ?? 0;

    const listResult = await this.#api.listIcms(generation);
    if (!listResult.ok) return;

    const icms = ((listResult.data as { icms?: IcmListRow[] }).icms ?? []).filter(
      (m) => m.enabled && !m.degraded
    );

    const treeResults = await Promise.all(icms.map((m) => this.#api.icmTree(m.mountKey, generation)));

    const groups: MountGroup[] = [];
    treeResults.forEach((result, i) => {
      if (!result.ok) return;
      const data = result.data as { mountKey: string; title: string; tree?: Record<string, any>[] };
      const mountKey = icms[i].mountKey;
      groups.push({
        mount: mountKey,
        title: data.title,
        tree: (data.tree ?? []).map((n) => normalizeIcmNode(n, mountKey))
      });
    });

    this.groups = groups;
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
 *
 * CARRY-FORWARD (Task 9.1 — sidebar project groups): `recentSessionsStore`
 * is refreshed directly from `onWorkspace` below (on open, alongside
 * `icmStore.refetch()`), and `wireRecentSessionsEvents` is wired onto this
 * same shared channel for `mounts_changed`, same reasoning as
 * `wireMountsEvents` — see that function's own doc comment in
 * `recent-sessions.svelte.ts` for why `mounts_changed` (not `icm_changed`)
 * is the trigger, and why a live per-session-status push isn't wired here.
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
        void recentSessionsStore.refresh();
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
  wireRecentSessionsEvents(channel);
}
