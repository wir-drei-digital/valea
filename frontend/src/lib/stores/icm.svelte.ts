import { api, type Api } from '../api/client';
import type { IcmNode } from '../shell/nav';
import { workspaceStore } from './workspace.svelte';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';
import { wireAuditEvents } from './audit.svelte';
import { wireMailEvents } from './mail.svelte';
import { mountsStore, wireMountsEvents } from './mounts.svelte';
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

  /**
   * `icm_changed` push subscribers beyond this store's own `refetch()`
   * reaction (see `handleIcmChanged` below) — same rationale as
   * `MailStore#onMailStatus`'s doc comment (`mail.svelte.ts`): a route that
   * needs to react to the SAME push (the Today page, Spec D §C — a
   * `today.json` file changed on disk) without opening a second, racing
   * `channel.on('icm_changed', ...)` binding on the shared `workspace:events`
   * channel (`wireIcmEvents`'s own doc comment: only ONE join per topic
   * reliably receives pushes, and this store's `handleIcmChanged` is already
   * the sole handler wired to that one join).
   */
  #icmChangedListeners = new Set<() => void>();

  constructor(api: IcmApi) {
    this.#api = api;
  }

  /**
   * `generation` is optional — every cold-load/route-level caller (`AppFrame`,
   * `+page.svelte`, `handleMountsChanged`, `handleIcmChanged` below) still
   * calls this bare and gets `workspaceStore.generation` as before. The one caller
   * that MUST supply it explicitly is `handleWorkspaceEvent` below (the LIVE
   * SWITCH path): see its doc comment for why reading `workspaceStore.generation`
   * at that call site is a guaranteed-stale read, not just a possible race.
   */
  async refetch(generation?: number): Promise<void> {
    const gen = generation ?? workspaceStore.generation ?? 0;

    const listResult = await this.#api.listIcms(gen);
    if (!listResult.ok) return;

    const icms = ((listResult.data as { icms?: IcmListRow[] }).icms ?? []).filter(
      (m) => m.enabled && !m.degraded
    );

    const treeResults = await Promise.all(icms.map((m) => this.#api.icmTree(m.mountKey, gen)));

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

  /**
   * `icm_changed` push handler — refetches the tree unconditionally, same
   * "just refetch on any related push" simplicity `mailStore`/`auditStore`
   * already use for their own change pushes, then notifies any additional
   * subscribers (see `#icmChangedListeners`'s doc comment above).
   */
  handleIcmChanged(): void {
    void this.refetch();
    this.#icmChangedListeners.forEach((listener) => listener());
  }

  /**
   * Subscribes to `icm_changed` pushes, IN ADDITION to this store's own
   * `refetch()` reaction above — same shape and rationale as
   * `MailStore#onMailStatus`. The Today page (`routes/+page.svelte`) hooks
   * this to refetch `cockpit_today`: `today.json` files live inside each
   * ICM's own folder, and the ONLY way Valea learns one changed is this same
   * watcher push (Spec D §C: "Valea never writes the file; changes ride the
   * existing `icm_changed` watcher events") — without the refetch, Today
   * would freeze whatever `today.json` snapshot its single mount-time load
   * happened to catch. Returns an unsubscribe function — call it from the
   * caller's cleanup (e.g. `onMount`'s returned callback) so a route that
   * unmounts doesn't leak a listener that outlives it.
   */
  onIcmChanged(listener: () => void): () => void {
    this.#icmChangedListeners.add(listener);
    return () => this.#icmChangedListeners.delete(listener);
  }
}

export const icmStore = new IcmStore(api);

/**
 * Refreshes the two stores the sidebar's ICM project groups
 * (`IcmProjects.svelte`) derive from — `mountsStore` (the group rows) and
 * `recentSessionsStore` (each group's sessions). TWO call sites, one per
 * path a workspace becomes "open" on:
 *
 * - COLD LOAD: the root layout (`+layout.svelte`) calls this once its
 *   bootstrap `workspaceStore.refresh()` (the `get_workspace` RPC) resolves
 *   with an open workspace. This call site exists because the backend's
 *   `WorkspaceEventsChannel.join/3` pushes NOTHING on join — the `workspace`
 *   push (and with it `wireIcmEvents`'s `onWorkspace` handler below) only
 *   fires on live `workspace_opened`/`workspace_closed` PubSub broadcasts,
 *   never on an initial page load — so without it, a cold load on any route
 *   that doesn't refresh these stores in its own `onMount` (everything but
 *   `/chat`, which refreshes `mountsStore` for `startSession`, and
 *   `/knowledge`) leaves the sidebar's ICM section empty.
 * - LIVE SWITCH: `handleWorkspaceEvent` below, right after the unconditional
 *   resets.
 *
 * Fire-and-forget (`void`) internally, same as every other push-driven
 * refresh in this module. `icmStore.refetch()` is deliberately NOT part of
 * this helper: on cold load every route already refetches it in its own
 * `onMount` (`AppFrame.svelte`, Today's inline shell), and the switch path
 * calls it separately alongside this.
 *
 * `generation` is optional and forwarded ONLY to `mountsStore.refresh` —
 * `recentSessionsStore.refresh` takes no `generation` at all (`Valea.Agents.
 * list_recent_sessions_by_icm/1` is a plain read, unguarded — see its own
 * moduledoc). The cold-load call site (`+layout.svelte`) calls this bare,
 * same as before: by the time it runs, `workspaceStore.refresh()` has
 * already resolved, so `mountsStore.refresh()`'s own `workspaceStore.generation`
 * fallback is already correct. `handleWorkspaceEvent` is the one caller that
 * MUST supply this explicitly — see its doc comment.
 */
export function refreshSidebarProjectStores(generation?: number): void {
  void mountsStore.refresh(generation);
  void recentSessionsStore.refresh();
}

let icmEventsWired = false;

/**
 * Runs the LIVE-SWITCH reset+refresh sequence for a `workspace` channel
 * push. Extracted from `wireIcmEvents`'s `onWorkspace` handler (below) into
 * its own exported function so it can be unit-tested directly — `wireIcmEvents`
 * itself only ever wires this onto a real `joinWorkspaceEvents` socket
 * connection, which nothing in this test suite stands up.
 *
 * The store owns its own coherence: on every workspace change (close, open,
 * or switch), the previous workspace's tree/catalog/session-groups are no
 * longer valid, so all three are dropped before anything else runs. When the
 * new workspace is open, immediately refetch/refresh so `loaded` reflects
 * the NEW data rather than sitting on the stale one — and see the
 * "CARRY-FORWARD (acceptance fix wave...)" paragraph on `wireIcmEvents`
 * below for exactly why `payload.generation` (not `workspaceStore.generation`)
 * is what gets threaded into that refetch/refresh.
 */
export function handleWorkspaceEvent(payload: WorkspaceEventPayload): void {
  icmStore.reset();
  recentSessionsStore.reset();
  mountsStore.reset();
  if (payload.open) {
    void icmStore.refetch(payload.generation);
    refreshSidebarProjectStores(payload.generation);
  }
}

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
 * CARRY-FORWARD (T20, post Spec-D deletion wave): also wires `wireAuditEvents`
 * onto the SAME channel this join returns, right here — not a second call
 * site. `wireAuditEvents` takes an already-joined channel rather than
 * joining its own for exactly this reason: a second independent
 * `workspace:events` join races this one and only one reliably receives
 * pushes. `wireAuditEvents` is currently a no-op placeholder (its
 * `queue_changed` listener was removed alongside the queue/workflow
 * subsystem — see its own doc comment in `audit.svelte.ts`); left wired here
 * so a future live audit event has a ready call site.
 *
 * CARRY-FORWARD (T16 — `/mail` route): also wires `wireMailEvents` onto the
 * same shared channel, same reasoning again — `mail_status`/`mail_sync`/
 * `mail_message`/`mailbox_ops` all ride this one `workspace:events` join
 * rather than the `/mail` route opening its own (see `wireMailEvents`'s doc
 * comment in `mail.svelte.ts` for why a route-local join would race this
 * one). `mailStore` stays live in the background exactly like `auditStore`
 * already does, not only while `/mail` is mounted.
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
 * is reset unconditionally and refreshed directly from `onWorkspace` below
 * (reset on every workspace change, refetch only on open, alongside
 * `icmStore.reset()`/`refetch()` — fix wave, Finding 2), and
 * `wireRecentSessionsEvents` is wired onto this same shared channel for
 * `mounts_changed`, same reasoning as `wireMountsEvents` — see that
 * function's own doc comment in `recent-sessions.svelte.ts` for why
 * `mounts_changed` (not `icm_changed`) is the trigger, and why a live
 * per-session-status push isn't wired here.
 *
 * CARRY-FORWARD (browser-verified fix wave — sidebar ICM groups): the
 * sidebar's project stores stay coherent across BOTH paths a workspace
 * becomes open on. LIVE SWITCH: `mountsStore` is reset unconditionally and
 * refreshed on open directly from `onWorkspace` below, same place and same
 * reasoning as `icmStore`/`recentSessionsStore` immediately above (before
 * this fix it had neither, so a workspace switch left the previous
 * workspace's catalog in place until a route-level `refresh()` happened to
 * run). COLD LOAD: `onWorkspace` NEVER runs on initial page load — the
 * backend's `WorkspaceEventsChannel.join/3` pushes nothing on join; the
 * `workspace` push only fires on live `workspace_opened`/`workspace_closed`
 * PubSub broadcasts — so the root layout's bootstrap covers that path by
 * calling `refreshSidebarProjectStores()` (above) once its `get_workspace`
 * RPC resolves open. The route-level `refresh()` calls in `chat`/`knowledge`
 * stay in place — a redundant fetch on top of these, same as `icmStore`'s
 * existing double-fetch pattern.
 *
 * CARRY-FORWARD (acceptance fix wave, Task 9.3/9.4 re-review Finding 2 —
 * generation-coherent refresh): the LIVE-SWITCH branch (`handleWorkspaceEvent`
 * below) threads the PUSH'S OWN `payload.generation` into `icmStore.refetch`/
 * `mountsStore.refresh`, NOT `workspaceStore.generation`. At the moment this
 * handler runs, `workspaceStore.generation` is GUARANTEED to still hold the
 * OUTGOING workspace's value, not a rare race: the root layout's `onWorkspace`
 * pass-through (called at the end of `handleWorkspaceEvent`'s caller, below)
 * is what re-syncs `workspaceStore` via `workspaceStore.refresh()` — an async
 * RPC round trip that hasn't even been kicked off yet, let alone resolved,
 * while this synchronous handler body is still running. So every LIVE switch
 * sent `list_icms`/`icm_tree` the OUTGOING generation while the backend's
 * `Valea.Workspace.Manager.current/0` already reflected the incoming
 * workspace — `Valea.Api.Icms`'s `check_generation/1` guard rejected every
 * one of them with `workspace_changed`, `icmStore`/`mountsStore` stayed reset
 * (empty) forever, and the sidebar's ICM groups + recent sessions rendered
 * empty until a manual reload re-ran the cold-load bootstrap. The backend's
 * `workspace_opened` broadcast already carries the correct NEW `generation`
 * in the SAME push (`WorkspaceEventsChannel.handle_info/2`) — threading it
 * straight through sidesteps the ordering dependency entirely, rather than
 * sequencing these refreshes after `workspaceStore.refresh()` resolves.
 * `recentSessionsStore.refresh()` needs no such argument — `list_recent_sessions_by_icm`
 * is a plain unguarded read (see its own moduledoc) — but it was still
 * collateral damage: `IcmProjects.svelte`'s rows are `mountsStore.mounts`
 * filtered/mapped (`icm-projects.ts`'s `orderGroups`), so an empty
 * `mountsStore.mounts` alone renders zero sidebar rows regardless of what
 * `recentSessionsStore` holds.
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
      handleWorkspaceEvent(payload);
      onWorkspace?.(payload);
    },
    onIcmChanged: () => icmStore.handleIcmChanged()
  });

  wireAuditEvents(channel);
  wireMailEvents(channel);
  wireMountsEvents(channel);
  wireRecentSessionsEvents(channel);
}
