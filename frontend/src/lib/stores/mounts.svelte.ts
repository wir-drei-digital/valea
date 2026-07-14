import { api, type Api } from '../api/client';
import { icmStore } from './icm.svelte';
import { workspaceStore } from './workspace.svelte';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as the other T16+ stores, so tests can inject a fake without
 * implementing every wrapped call. Task 3.4: renamed to the `Valea.Api.Icms`
 * (C9) wrappers — `listMounts`/`setMountEnabled`/`createMount`/
 * `declareMount`/`undeclareMount`/`mountsDoctor` (still live on
 * `Valea.Api.Mounts` until Phase 11 deletes it) are no longer called from
 * this store.
 */
type MountsApi = Pick<Api, 'listIcms' | 'setIcmEnabled' | 'createIcm' | 'mountIcm' | 'unmountIcm' | 'icmDoctor'>;

/**
 * One row of `list_icms` — mirrors `listIcmsFields` in `api/client.ts`.
 * Task 3.4: replaces the `Valea.Api.Mounts`-era shape (`name` = mount key,
 * `title` = display name, `relRoot`/`root`) with the C9 id-based one —
 * `mountKey` is now the stable `icms:` config key (what `name` used to
 * mean), `name` is the ICM's own display name (what `title` used to mean),
 * and `id` is the manifest's stable UUID (`null` for a degraded mount with
 * no loadable manifest). `relRoot`/embedded-vs-external branching is gone
 * from this payload entirely — post-A2, EVERY mount is by-reference, so
 * `root` (the resolved absolute path) is always the real location, and
 * there is no embedded form left to distinguish it from.
 */
export type MountSummary = {
  mountKey: string;
  id: string | null;
  name: string;
  description: string;
  root: string;
  enabled: boolean;
  degraded: string | null;
};

/**
 * The mount catalog (`config/workspace.yaml`'s `icms:` map) — every ICM the
 * current workspace has mounted, enabled or not. Powers the mounts-
 * management UI: toggling a mount, mounting/creating one, and staying live
 * as the backend reports `mounts_changed` pushes (a mount manifest edit or
 * an RPC mutation — see `Valea.Api.Icms`'s moduledoc).
 */
/**
 * A reference-adoption declare-stage failure carried across the
 * onboarding-to-app transition (fix wave 1, A2-T9): `workspaceStore.create`
 * flips `state = 'open'` — and the root layout reactively swaps the
 * Onboarding screen out — BEFORE the mount resolves, so a failure landing
 * after that flip has no live onboarding card left to render on.
 * `adoptByReference` (onboarding-path.ts) persists it here; the Knowledge
 * page renders it as a dismissible banner (`adoptFailureBannerText`,
 * mount-sections.ts).
 */
export type PendingAdoptError = {
  /** The by-reference mount name the declare was attempted with. */
  name: string;
  /** The external folder path (exactly as picked — the declare's `ref`). */
  ref: string;
  /** Already-mapped readable copy (`declareMountErrorMessage` output), not a raw code. */
  message: string;
};

export class MountsStore {
  mounts: MountSummary[] = $state([]);
  loaded = $state(false);

  /**
   * Non-null only between a declare-stage reference-adoption failure and
   * the user dismissing the Knowledge page's banner (or a later
   * `setPendingAdoptError` overwriting it). Never set by a create-stage
   * failure — that happens while the onboarding card is still mounted,
   * which renders its own `referenceError` instead (see
   * `adoptByReference`'s doc comment in onboarding-path.ts).
   */
  pendingAdoptError: PendingAdoptError | null = $state(null);

  #api: MountsApi;

  constructor(api: MountsApi) {
    this.#api = api;
  }

  setPendingAdoptError(name: string, ref: string, message: string): void {
    this.pendingAdoptError = { name, ref, message };
  }

  /** Dismisses the adoption-failure banner. */
  clearPendingAdoptError(): void {
    this.pendingAdoptError = null;
  }

  /**
   * Task 3.4: unlike every mutating method below, `refresh` has no
   * caller-supplied `generation` — it is called bare from `+page.svelte`'s
   * `onMount` and from `handleMountsChanged` below, neither of which had a
   * generation to thread before `list_icms` started guarding one (see
   * `Valea.Api.Icms`'s moduledoc: it reads LIVE filesystem/manifest state,
   * same "mutating-adjacent" posture `mounts_doctor` already had). Rather
   * than push a `generation` parameter onto every zero-arg call site, this
   * reads it off `workspaceStore` directly — the one deliberate exception
   * to this module's usual "store-free api, caller supplies generation"
   * convention (see `api/client.ts`'s header comment and `setEnabled`/
   * `create`/`declare`/`undeclare` below, which keep taking it explicitly
   * since they already had a caller-supplied value to thread).
   */
  async refresh(): Promise<void> {
    const result = await this.#api.listIcms(workspaceStore.generation ?? 0);
    if (!result.ok) return;

    const data = result.data as { icms?: MountSummary[] };
    this.mounts = data.icms ?? [];
    this.loaded = true;
  }

  /**
   * Enables/disables a mount, addressed by `mountKey` (the `icms:` config
   * key — `MountSummary.mountKey`, NOT the display `name`). `generation` is
   * sourced from `workspaceStore` by the caller (not injected) — same
   * store-free-api convention `api/client.ts`'s header comment documents;
   * see `QueueStore.approve` for the identical pattern. Refetches the
   * catalog on success — the disk-level change also arrives via
   * `mounts_changed` (`handleMountsChanged` below), but that push isn't
   * guaranteed to beat this refetch, and re-running it is harmless.
   */
  async setEnabled(
    mountKey: string,
    enabled: boolean,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.setIcmEnabled(mountKey, enabled, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * Mints a brand-new external ICM at `path` (seeding the portable
   * template, per `Valea.Mounts.create/3`) and mounts it. Returns the
   * backend-assigned `mountKey`/`id` so a caller can navigate straight to
   * it without a second round trip. Refetches the catalog on success, same
   * reasoning as `setEnabled`.
   */
  async create(
    name: string,
    path: string,
    generation: number
  ): Promise<{ ok: true; mountKey: string; id: string } | { ok: false; error: string }> {
    const result = await this.#api.createIcm(name, path, generation);
    if (!result.ok) return { ok: false, error: result.error };

    const data = result.data as { mountKey: string; id: string };
    await this.refresh();
    return { ok: true, mountKey: data.mountKey, id: data.id };
  }

  /**
   * Mounts an already-existing, already-healthy external ICM folder at
   * `ref` (`Valea.Mounts.mount/2`, exposed as `mount_icm`). `name` is kept
   * as a parameter for call-site compatibility with the onboarding
   * "Use it where it is" flow and Knowledge's "Mount a folder from
   * elsewhere…" dialog (both still collect a name from the user) but is no
   * longer sent to the backend — the mount key is now DERIVED from the
   * target ICM's own manifest name (`Valea.Mounts.unique_mount_key/2`), the
   * same minimal-compiling-stopgap posture `Valea.Api.Mounts.declare_mount`
   * already documents for its own retired `name` argument. A real "pick a
   * name" UI (or dropping the field) is deeper UI work, not this task's
   * scope. Rejections (the 8 `Valea.Mounts.External.validate_ref/2`
   * reasons plus `invalid_mount_name`/`workspace_not_open`/
   * `workspace_changed`) map to readable copy via `declareMountErrorMessage`
   * below. Refetches the catalog on success, same reasoning as
   * `setEnabled`/`create`.
   */
  async declare(
    name: string,
    ref: string,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.mountIcm(ref, generation);
    if (!result.ok) return { ok: false, error: result.error };

    // Fix wave 2: a successful mount IS the retry the adoption-failure
    // banner points at ("Mount a folder from elsewhere…") — a user who just
    // mounted something shouldn't keep seeing "Couldn't mount…". A FAILED
    // mount deliberately leaves it: the persisted failure is still true.
    this.clearPendingAdoptError();
    await this.refresh();
    return { ok: true };
  }

  /**
   * Unmounts (`unmount_icm`) the mount named `mountKey` — config-only,
   * NEVER touches the folder itself (see `Valea.Mounts.unmount/2`'s
   * moduledoc: "never-delete promise" applies here as much as anywhere
   * else in this codebase). Rejects with `mount_not_found` when `mountKey`
   * isn't a currently-mounted `icms:` entry. Refetches the catalog on
   * success, same reasoning as `declare` above.
   */
  async undeclare(
    mountKey: string,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.unmountIcm(mountKey, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * Runs the ICM doctor (`icm_doctor` — a per-`mountKey` probe, see
   * `Valea.Api.Icms`'s moduledoc) against EVERY currently-mounted ICM and
   * flattens the results into the same `{ok, checks}` shape the old
   * whole-workspace `mounts_doctor` returned, so `MountsDoctorPanel.svelte`
   * needs no changes — it lists every mount via `list_icms`, then fans
   * `icm_doctor` out across every `mountKey` in parallel. Unlike
   * `declare`/`undeclare`/`setEnabled`/`create`, this NEVER calls
   * `refresh()` on success — it is a read-only probe of live state (the
   * watcher's current root set, the filesystem under each mount's resolved
   * root), not a config mutation, so there is nothing in `mounts`/`loaded`
   * for it to have made stale.
   */
  async doctor(
    generation: number
  ): Promise<{ ok: true; data: { ok: boolean; checks: unknown[] } } | { ok: false; error: string }> {
    const listResult = await this.#api.listIcms(generation);
    if (!listResult.ok) return { ok: false, error: listResult.error };

    const icms = (listResult.data as { icms?: MountSummary[] }).icms ?? [];
    const results = await Promise.all(icms.map((icm) => this.#api.icmDoctor(icm.mountKey, generation)));

    const firstFailure = results.find((r) => !r.ok);
    if (firstFailure && !firstFailure.ok) return { ok: false, error: firstFailure.error };

    const checks = results.flatMap((r) => (r.ok ? (r.data as { checks: unknown[] }).checks : []));
    const ok = results.every((r) => r.ok && (r.data as { ok: boolean }).ok);
    return { ok: true, data: { ok, checks } };
  }

  /**
   * Handles a `mounts_changed` push (wired below via `wireMountsEvents`).
   * Refetches BOTH this store's own catalog and `icmStore`'s tree: a mount
   * being enabled/disabled/mounted changes not just `list_icms`'s output
   * but also `icm_tree`'s grouping (a newly-enabled mount gains a group, a
   * disabled one loses one), so the two stores go stale together and must
   * refresh together. `icmStore` is imported directly rather than
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

/**
 * Readable copy for `mount_icm`'s error vocabulary (`Valea.Api.Icms.error_for/1`,
 * shared with `Valea.Api.Mounts.error_for/1`): the generation guard's own
 * two codes, `Valea.Mounts.validate_mount_name/1`'s `invalid_mount_name`,
 * and all EIGHT of `Valea.Mounts.External.validate_ref/2`'s reason atoms
 * (that function's `@doc` enumerates them: `not_absolute`,
 * `inside_workspace`, `ancestor_of_workspace`, `home_or_root`, `not_found`,
 * `no_manifest`, `unsafe_path`, and the 2-tuple `{:invalid_manifest,
 * reason}` — which `error_for/1` stringifies to the bare code
 * `"invalid_manifest"`, same as every other atom code, so this switch never
 * needs the nested reason string). Shared by the onboarding "Use it where
 * it is" flow (`onboarding-path.ts`'s `adoptByReference`) and Knowledge's
 * "Mount a folder from elsewhere…" dialog — both call `declare` above and
 * need the SAME mapping, so it lives here rather than being duplicated per
 * caller (mirrors `mail-shapes.ts` colocating `mailSetupErrorMessage` next
 * to `submitMailSetup`).
 */
export function declareMountErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'invalid_mount_name':
      return 'Give this mount a name without "/", "..", or control characters.';
    case 'not_absolute':
      return "Enter a full path (or one starting with ~) — a relative path can't be mounted.";
    case 'inside_workspace':
      return "That folder is already inside this workspace — it doesn't need mounting.";
    case 'ancestor_of_workspace':
      return 'That folder contains this workspace — mounting it would put the workspace inside itself.';
    case 'home_or_root':
      return "That's your entire home folder (or your whole disk) — pick something more specific.";
    case 'not_found':
      return "That folder doesn't exist. Check the path and try again.";
    case 'no_manifest':
      return "That folder doesn't look like a knowledge module yet — it needs an icm.yaml.";
    case 'unsafe_path':
      return "That path contains a character (*, ?, [, ], {, }, ( or )) that isn't safe to mount. Rename the folder or choose another.";
    case 'invalid_manifest':
      return 'That folder has an icm.yaml, but it could not be read. Check its contents and try again.';
    default:
      return 'Could not mount that folder. Check the path and try again.';
  }
}

/**
 * Readable copy for `unmount_icm`'s error vocabulary
 * (`Valea.Api.Icms.error_for/1` + `Valea.Mounts.unmount/2`'s own
 * `:mount_not_found` — `mountKey` has no `icms:` entry). Colocated with
 * `declareMountErrorMessage` above for the same reason.
 */
export function undeclareMountErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'mount_not_found':
      return "That mount isn't currently mounted — there's nothing to unmount.";
    default:
      return 'Could not unmount that folder. Try again.';
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
