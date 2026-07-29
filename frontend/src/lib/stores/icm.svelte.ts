import { api, type Api } from '../api/client';
import { findIcmNode, type IcmNode } from '../shell/nav';
import { workspaceStore } from './workspace.svelte';
import { joinWorkspaceEvents, type WorkspaceEventPayload } from '../socket';
import { wireMailEvents } from './mail.svelte';
import { wireCalendarEvents } from './calendar.svelte';
import { mountsStore, wireMountsEvents } from './mounts.svelte';
import { recentSessionsStore, wireRecentSessionsEvents } from './recent-sessions.svelte';

type IcmApi = Pick<Api, 'icmListDir' | 'listIcms'>;

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

    // Lazy-tree marker: an `icm_list_dir` folder entry carries NO
    // `children` at all (one level only — `Valea.ICM.list_dir/2`), so its
    // placeholder `[]` is stamped `childrenLoaded: false`; a full-tree
    // (`icm_tree`) node arrives with a real array and stays loaded.
    return {
      name: raw.name,
      path: raw.path,
      mountKey,
      type: 'folder',
      children: Array.isArray(raw.children) ? raw.children.map((c: Record<string, any>) => normalizeIcmNode(c, mountKey)) : [],
      childrenLoaded: Array.isArray(raw.children),
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
   * order. LAZY since the file-browser performance pass: `refetch` fetches
   * only each mount's ROOT level (`icm_list_dir` with `""`) plus whatever
   * deeper folders were already loaded this session (`#loadedDirs`), and
   * `loadDir`/`ensurePathLoaded` fill folders in on demand (tree expand,
   * deep links) — a large mount is never walked wholesale up front. Every
   * other consumer (`mount-sections.ts`, the Knowledge routes) still sees
   * the same grouped shape; folders that haven't been fetched yet carry
   * `childrenLoaded: false` with a `[]` placeholder.
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
  /**
   * Folder rel-paths (`''` = the mount root) whose single-level listings
   * have been fetched this session, per mount key. `refetch` re-fetches
   * exactly these — so an `icm_changed` push keeps every part of the tree
   * the user has actually opened fresh, without ever walking the rest.
   */
  #loadedDirs = new Map<string, Set<string>>();

  /** In-flight `loadDir` de-dupe — `ensurePathLoaded` awaits these instead of double-fetching. */
  #inFlight = new Map<string, Promise<void>>();

  async refetch(generation?: number): Promise<void> {
    const gen = generation ?? workspaceStore.generation ?? 0;

    const listResult = await this.#api.listIcms(gen);
    if (!listResult.ok) return;

    const icms = ((listResult.data as { icms?: IcmListRow[] }).icms ?? []).filter(
      (m) => m.enabled && !m.degraded
    );

    const groups = await Promise.all(icms.map((m) => this.#rebuildMountGroup(m.mountKey, gen)));

    this.groups = groups.filter((g): g is MountGroup => g !== null);

    // Reconcile: a concurrent `loadDir` may have grafted into the tree this
    // assignment just replaced and still marked its dir loaded — drop any
    // mark whose node isn't actually populated in the NEW tree, so the next
    // expand/ensure re-fetches instead of no-oping forever.
    for (const group of this.groups) {
      const marked = this.#loadedDirs.get(group.mount);
      if (!marked) continue;
      for (const dir of [...marked]) {
        if (dir === '') continue;
        const node = findIcmNode(group.tree, dir);
        if (!node || node.type !== 'folder' || node.childrenLoaded !== true) marked.delete(dir);
      }
    }

    this.loaded = true;
  }

  /**
   * Rebuilds ONE mount's (partial) tree: the root listing, plus every
   * deeper folder in `#loadedDirs` re-fetched and grafted back in — all
   * listings fetched in parallel, grafted shallow-to-deep so a child dir
   * always finds its (just-grafted) parent node. A dir that fails to list
   * (deleted since it was loaded, transient error) falls out of
   * `#loadedDirs`, so it isn't re-fetched forever. Returns `null` when the
   * ROOT listing fails — the mount drops out of `groups` entirely, same as
   * a failed `icm_tree` fetch always did.
   */
  async #rebuildMountGroup(mountKey: string, gen: number): Promise<MountGroup | null> {
    const dirs = [...(this.#loadedDirs.get(mountKey) ?? [])]
      .filter((d) => d !== '')
      .sort((a, b) => a.split('/').length - b.split('/').length);

    const [rootResult, ...dirResults] = await Promise.all([
      this.#api.icmListDir(mountKey, '', gen),
      ...dirs.map((d) => this.#api.icmListDir(mountKey, d, gen))
    ]);

    if (!rootResult.ok) return null;
    const rootData = rootResult.data as { title: string; entries?: Record<string, any>[] };
    const tree = (rootData.entries ?? []).map((n) => normalizeIcmNode(n, mountKey));

    const stillLoaded = new Set(['']);
    dirResults.forEach((result, i) => {
      if (!result.ok) return;
      const node = findIcmNode(tree, dirs[i]);
      if (!node || node.type !== 'folder') return;
      const data = result.data as { entries?: Record<string, any>[] };
      node.children = (data.entries ?? []).map((n) => normalizeIcmNode(n, mountKey));
      node.childrenLoaded = true;
      stillLoaded.add(dirs[i]);
    });
    this.#loadedDirs.set(mountKey, stillLoaded);

    return { mount: mountKey, title: rootData.title, tree };
  }

  /**
   * Fetches ONE folder's single-level listing (`''` = the mount root) and
   * grafts it into the live tree — the on-demand half of the lazy tree
   * (folder expand, `ensurePathLoaded`). No-ops when that dir is already
   * loaded; concurrent calls for the same dir share one fetch. A dir the
   * backend reports `not_found` for is marked loaded-and-empty rather than
   * left spinning — the `icm_changed` push that follows an external delete
   * prunes the node itself.
   */
  loadDir(mountKey: string, path: string): Promise<void> {
    if (this.#loadedDirs.get(mountKey)?.has(path)) return Promise.resolve();

    const key = `${mountKey}\0${path}`;
    const inFlight = this.#inFlight.get(key);
    if (inFlight) return inFlight;

    const promise = this.#fetchAndGraft(mountKey, path).finally(() => {
      this.#inFlight.delete(key);
    });
    this.#inFlight.set(key, promise);
    return promise;
  }

  async #fetchAndGraft(mountKey: string, path: string): Promise<void> {
    const result = await this.#api.icmListDir(mountKey, path, workspaceStore.generation ?? 0);
    if (!result.ok) {
      // A deleted-underneath folder is marked loaded-and-empty (the
      // `icm_changed` push that follows prunes the node itself); any other
      // failure is transient — leave it unmarked so the next expand retries.
      if (result.error !== 'not_found' || path === '') return;
      this.#graft(mountKey, path, []);
      this.#markLoaded(mountKey, path);
      return;
    }

    const data = result.data as { title: string; entries?: Record<string, any>[] };
    const children = (data.entries ?? []).map((n) => normalizeIcmNode(n, mountKey));

    if (path === '') {
      // A deep link's `ensurePathLoaded` can win the race against the
      // cold-load `refetch()` — create the group rather than dropping the
      // graft; `refetch` replaces the whole array in `list_icms` order when
      // it lands anyway.
      const group = this.groups.find((g) => g.mount === mountKey);
      if (group) {
        group.title = data.title;
        group.tree = children;
      } else {
        this.groups.push({ mount: mountKey, title: data.title, tree: children });
      }
    } else {
      this.#graft(mountKey, path, children);
    }
    this.#markLoaded(mountKey, path);
  }

  #graft(mountKey: string, path: string, children: IcmNode[]): void {
    const node = this.#findNode(mountKey, path);
    if (!node || node.type !== 'folder') return;
    node.children = children;
    node.childrenLoaded = true;
  }

  #markLoaded(mountKey: string, path: string): void {
    const set = this.#loadedDirs.get(mountKey) ?? new Set<string>();
    set.add(path);
    this.#loadedDirs.set(mountKey, set);
  }

  /**
   * Loads every ancestor level of `path` (root first) so the node at
   * `path` exists in the tree — the deep-link entry point for
   * `/knowledge/<mountKey>/<rel...>`. If the node is itself a folder, its
   * own listing is loaded too (the route's list pane shows its children).
   * Returns the node, or `undefined` when some segment doesn't exist —
   * which, unlike the pre-lazy full tree, is now a definitive answer only
   * AFTER this resolves (callers keep their loading state until then).
   */
  async ensurePathLoaded(mountKey: string, path: string): Promise<IcmNode | undefined> {
    await this.loadDir(mountKey, '');

    if (path === '') return undefined;

    const segments = path.split('/');
    let node: IcmNode | undefined;
    for (let i = 0; i < segments.length; i++) {
      const ancestor = segments.slice(0, i + 1).join('/');
      node = this.#findNode(mountKey, ancestor);
      if (!node) return undefined;
      if (node.type !== 'folder') return i === segments.length - 1 ? node : undefined;
      await this.loadDir(mountKey, node.path);
    }
    return node;
  }

  /**
   * Loads every folder named `templates` (case-insensitive) reachable
   * through already-loaded levels, to a fixpoint — the template picker
   * (`NewEntryDialog` → `template-options.ts`) walks the loaded tree, so
   * without this a lazy tree would offer no templates until the user
   * happened to expand the folder by hand. A `templates/` folder buried
   * inside a folder that has never been listed stays undiscovered — the
   * deliberate trade for not walking whole mounts.
   */
  async loadTemplateFolders(mountKey: string): Promise<void> {
    await this.loadDir(mountKey, '');

    for (;;) {
      const group = this.groups.find((g) => g.mount === mountKey);
      if (!group) return;

      const pending: string[] = [];
      const walk = (nodes: IcmNode[]) => {
        for (const node of nodes) {
          if (node.type !== 'folder') continue;
          if (node.name.toLowerCase() === 'templates' && node.childrenLoaded === false) {
            pending.push(node.path);
          }
          walk(node.children ?? []);
        }
      };
      walk(group.tree);

      if (pending.length === 0) return;
      await Promise.all(pending.map((p) => this.loadDir(mountKey, p)));
    }
  }

  #findNode(mountKey: string, path: string): IcmNode | undefined {
    const group = this.groups.find((g) => g.mount === mountKey);
    return group ? findIcmNode(group.tree, path) : undefined;
  }

  /**
   * Clears the tree back to its cold-start shape. Called on every
   * workspace-change push so a stale tree from the previous workspace can
   * never be mistaken for the new one's — see `wireIcmEvents` below.
   */
  reset(): void {
    this.groups = [];
    this.loaded = false;
    this.#loadedDirs = new Map();
    this.#inFlight = new Map();
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
 * CARRY-FORWARD (T16 — `/mail` route): also wires `wireMailEvents` onto the
 * same shared channel, right here — not a second call site. `wireMailEvents`
 * takes an already-joined channel rather than joining its own for exactly
 * this reason: a second independent `workspace:events` join races this one
 * and only one reliably receives pushes. `mail_status`/`mail_sync`/
 * `mail_message` all ride this one `workspace:events` join rather than the
 * `/mail` route opening its own (see `wireMailEvents`'s doc comment in
 * `mail.svelte.ts` for why a route-local join would race this one).
 * `mailStore` stays live in the background, not only while `/mail` is
 * mounted.
 *
 * `auditStore` has no live push to react to — the queue-decision push
 * listener that used to keep it fresh mid-session was removed alongside the
 * queue/workflow subsystem (Spec D deletion wave); it now only refetches on
 * `routes/audit/+page.svelte`'s `onMount`, which is sufficient since there
 * is no more live queue activity to reflect mid-session.
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

  wireMailEvents(channel);
  wireCalendarEvents(channel);
  wireMountsEvents(channel);
  wireRecentSessionsEvents(channel);
}
