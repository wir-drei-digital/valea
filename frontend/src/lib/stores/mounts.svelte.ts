import { api, type Api } from '../api/client';
import { icmStore } from './icm.svelte';
import type { Channel } from 'phoenix';

/**
 * Minimal surface of `api` this store depends on — same `Pick<Api, ...>`
 * convention as the other T16+ stores, so tests can inject a fake without
 * implementing every wrapped call.
 */
type MountsApi = Pick<
  Api,
  'listMounts' | 'setMountEnabled' | 'createMount' | 'declareMount' | 'undeclareMount' | 'mountsDoctor'
>;

/**
 * One row of `list_mounts` — mirrors `listMountsFields` in `api/client.ts`.
 * `relRoot`/`root`/`enabled`/`degraded` are NESTED array-item fields on the
 * backend's typed `:map` action (see `Valea.Api.Mounts`'s moduledoc), so
 * unlike a top-level boolean-returning field, they arrive already
 * camelCased with no falsy-map-field workaround needed. `degraded` is
 * `null` for a healthy mount, a reason string otherwise (e.g.
 * `"manifest_missing"`).
 *
 * `relRoot` is `null` for an EXTERNAL (by-reference, A2-T8) mount — it has
 * no workspace-relative path. `root` is the one field ALWAYS present
 * (never `null`): the mount's absolute directory, embedded or external —
 * use it (not `relRoot`) to show an external mount's real location.
 */
export type MountSummary = {
  name: string;
  title: string;
  description: string;
  relRoot: string | null;
  root: string;
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
/**
 * A reference-adoption declare-stage failure carried across the
 * onboarding-to-app transition (fix wave 1, A2-T9): `workspaceStore.create`
 * flips `state = 'open'` — and the root layout reactively swaps the
 * Onboarding screen out — BEFORE `declare_mount` resolves, so a declare
 * failure landing after that flip has no live onboarding card left to
 * render on. `adoptByReference` (onboarding-path.ts) persists it here; the
 * Knowledge page renders it as a dismissible banner
 * (`adoptFailureBannerText`, mount-sections.ts).
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
   * Declares an EXTERNAL (by-reference, A2-T8/A2-T9) mount: `name` becomes
   * the config key, `ref` the folder's path (absolute or `~`-based — the
   * onboarding "Use it where it is" flow and Knowledge's "Mount a folder
   * from elsewhere…" dialog both pass the exact path the user picked,
   * un-normalized, same as `workspaceStore.adopt`'s `icmSourcePath`).
   * Rejections (the 8 `Valea.Mounts.External.validate_ref/2` reasons plus
   * `invalid_mount_name`/`workspace_not_open`/`workspace_changed`) map to
   * readable copy via `declareMountErrorMessage` below — this method itself
   * only threads the raw code through, same "don't map errors in the
   * store" convention `setEnabled`/`create` already use. Refetches the
   * catalog on success, same reasoning as `setEnabled`/`create`.
   */
  async declare(
    name: string,
    ref: string,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.declareMount(name, ref, generation);
    if (!result.ok) return { ok: false, error: result.error };

    // Fix wave 2: a successful declare IS the retry the adoption-failure
    // banner points at ("Mount a folder from elsewhere…") — a user who just
    // mounted something shouldn't keep seeing "Couldn't mount…". A FAILED
    // declare deliberately leaves it: the persisted failure is still true.
    this.clearPendingAdoptError();
    await this.refresh();
    return { ok: true };
  }

  /**
   * Undeclares (unmounts) an EXTERNAL mount named `name` — config-only,
   * NEVER touches the folder itself (see `Valea.Mounts.undeclare/2`'s
   * moduledoc: "never-delete promise" applies here as much as anywhere
   * else in this codebase). Rejects with `mount_not_declared` when `name`
   * isn't currently an external mount (embedded, or already gone).
   * Refetches the catalog on success, same reasoning as `declare` above.
   */
  async undeclare(
    name: string,
    generation: number
  ): Promise<{ ok: true } | { ok: false; error: string }> {
    const result = await this.#api.undeclareMount(name, generation);
    if (!result.ok) return { ok: false, error: result.error };

    await this.refresh();
    return { ok: true };
  }

  /**
   * Runs the mounts doctor (`Valea.Mounts.Doctor.run/1` via
   * `mounts_doctor`) — per-mount health checks, same `{id, label, status,
   * detail, remedy}` shape `Valea.Mail.Doctor`'s `mail_doctor` uses (see
   * `MountsDoctorPanel.svelte`'s `normalizeMountsDoctorChecks` for the
   * defensive narrowing of the unconstrained `checks` payload). Unlike
   * `declare`/`undeclare`/`setEnabled`/`create`, this NEVER calls
   * `refresh()` on success — it is a read-only probe of live state (the
   * watcher's current root set, the filesystem under each external mount's
   * resolved root), not a config mutation, so there is nothing in
   * `mounts`/`loaded` for it to have made stale.
   */
  async doctor(
    generation: number
  ): Promise<{ ok: true; data: { ok: boolean; checks: unknown[] } } | { ok: false; error: string }> {
    const result = await this.#api.mountsDoctor(generation);
    if (!result.ok) return { ok: false, error: result.error };

    const data = result.data as { ok: boolean; checks: unknown[] };
    return { ok: true, data };
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

/**
 * Readable copy for `declare_mount`'s error vocabulary
 * (`Valea.Api.Mounts.error_for/1`): the generation guard's own two codes,
 * `Valea.Mounts.validate_mount_name/1`'s `invalid_mount_name`, and all
 * EIGHT of `Valea.Mounts.External.validate_ref/2`'s reason atoms (that
 * function's `@doc` enumerates them: `not_absolute`, `inside_workspace`,
 * `ancestor_of_workspace`, `home_or_root`, `not_found`, `no_manifest`,
 * `unsafe_path`, and the 2-tuple `{:invalid_manifest, reason}` — which
 * `error_for/1` stringifies to the bare code `"invalid_manifest"`, same as
 * every other atom code, so this switch never needs the nested reason
 * string). Shared by the onboarding "Use it where it is" flow
 * (`onboarding-path.ts`'s `adoptByReference`) and Knowledge's "Mount a
 * folder from elsewhere…" dialog — both call `declare` above and need the
 * SAME mapping, so it lives here rather than being duplicated per caller
 * (mirrors `mail-shapes.ts` colocating `mailSetupErrorMessage` next to
 * `submitMailSetup`).
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
 * Readable copy for `undeclare_mount`'s error vocabulary
 * (`Valea.Api.Mounts.error_for/1` + `Valea.Mounts.undeclare/2`'s own
 * `:mount_not_declared` — `name` has no config entry, or has one that
 * isn't `kind: "path"`). Colocated with `declareMountErrorMessage` above
 * for the same reason.
 */
export function undeclareMountErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'Your workspace changed. Reopen it and try again.';
    case 'mount_not_declared':
      return "That mount isn't a by-reference mount — there's nothing to unmount.";
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
