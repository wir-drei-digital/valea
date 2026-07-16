// Pure orchestration for the two onboarding paths (Tasks 10.2/10.3):
// "Start fresh" (`startFresh`, create a hidden workspace + a brand-new ICM)
// and "Use existing ICM" (`useExistingIcm`, preview a folder via `inspect_icm`
// then create a hidden workspace + mount that folder by reference). Kept
// pure and separate from the components so the orchestration order — the
// part most worth getting exactly right, since a wrong step order can leave
// a half-open workspace with a silently-lost error — is testable without
// mounting Svelte.
//
// Task 10.3 removes this module's earlier `decideOnboardingMode`/
// `adoptByReference` machinery (the A-T16/A2-T9 `inspect_path`-based
// open-or-adopt-by-move-or-adopt-by-reference branch, superseded by
// `inspect_icm`-based onboarding across BOTH paths — see `Valea.Api.Icms`'s
// moduledoc for why `inspect_icm` needs no open workspace either) —
// `Valea.Workspace.Adopt`/`inspect_path`/`adopt_workspace` are deleted from
// the backend entirely (Phase 11).
import { createIcmErrorMessage, declareMountErrorMessage } from '$lib/stores/mounts.svelte';

/** Last path segment, ignoring a trailing slash. POSIX paths only (macOS/Linux). */
export function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx === -1 ? trimmed : trimmed.slice(idx + 1);
}

// -- Task 10.2: "Start fresh" ------------------------------------------------

/**
 * Default folder suggestion for a brand-new ICM, shown live as the user
 * types its name in `CreateWorkspaceDialog.svelte` ("Start fresh"):
 * `~/Documents/Valea/<name>`, a `~`-form path passed straight through to
 * `createIcm` untouched (mirrors `mountIcm`'s own "stored exactly as
 * picked/typed" contract — see `api/client.ts`'s `mountIcm` doc comment). A
 * blank/whitespace-only name falls back to the bare `~/Documents/Valea`
 * folder, so the live suggestion never carries a trailing empty segment
 * while the name field is still untouched.
 */
export function defaultIcmFolder(name: string): string {
  const trimmed = name.trim();
  return trimmed ? `~/Documents/Valea/${trimmed}` : '~/Documents/Valea';
}

/**
 * Dependencies `startFresh` needs, injected the same way `useExistingIcm`
 * below is — testable without a real store or RPC round trip.
 */
export type StartFreshDeps = {
  /** `Valea.Api.Workspace.create_workspace` (id-based, app-owned — no path). */
  createWorkspace: (name: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  /**
   * `Valea.Api.Icms.create_icm` — mints a brand-new ICM at `folder` (seeding
   * the portable template) and mounts it. Reads the CURRENT generation via
   * `currentGeneration`, same post-create-only-trusted rule
   * `UseExistingIcmDeps.currentGeneration` documents below.
   */
  createIcm: (
    name: string,
    folder: string,
    generation: number
  ) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
  /** Reads the CURRENT generation — a closure, not a value, and always called AFTER `createWorkspace` resolves (mirrors `mail-shapes.ts`'s `refreshWorkspaceId`): the only generation this function can trust is the freshly-created workspace's own. `null` means the workspace isn't open (unexpected). */
  currentGeneration: () => number | null;
  /**
   * Persists a create-ICM-stage failure so it survives the onboarding-to-app
   * transition: `createWorkspace` already flipped `workspaceStore.state` to
   * 'open' by the time this can fail — the root layout reactively swaps the
   * Onboarding screen out, unmounting the card that would otherwise render a
   * local error. Wired to `mountsStore.setPendingAdoptError` — the SAME
   * store field `useExistingIcm`'s own mount-stage failure uses below — a
   * successful "Mount a folder from elsewhere…" retry against the same
   * `folder` clears it either way, and `createIcm` may have already written
   * a healthy `icm.yaml` to `folder` before the mount step itself failed,
   * making that retry path a real recovery, not a dead end.
   */
  setPendingIcmError: (name: string, folder: string, message: string) => void;
  /** Navigates to Knowledge — the surface that renders the persisted error (the Knowledge page's dismissible banner). */
  goToKnowledge: () => void;
  /** Navigates to the new ICM's first chat session (`/chat?icm=<mountKey>`) on success. */
  goToFirstSession: (mountKey: string) => void;
};

export type StartFreshOutcome =
  | { ok: true; mountKey: string }
  | { ok: false; stage: 'create-workspace' | 'create-icm'; error: string };

/**
 * Orchestrates "Start fresh" (Task 10.2): scaffolds a brand-new, hidden,
 * id-based workspace (`createWorkspace`), then mints a brand-new ICM at
 * `folder` inside it (`createIcm`) — Valea never creates ICM content under
 * the hidden workspace itself; the ICM always lives at the user-chosen
 * `folder`.
 *
 * `workspaceName` is the dialog's secondary, editable field — the workspace
 * name IS user-visible after onboarding (`WorkspaceSwitcher`'s current-name
 * row and recent list, `Onboarding.svelte`'s own Recent list), so it gets
 * its own field per the brief: "Workspace name defaults from the ICM name,
 * adjustable in a secondary field." `null`/blank falls back to `name` (the
 * ICM name) — the same fallback contract `useExistingIcm`'s `workspaceName`
 * has below. Only the workspace path stays hidden, never the name.
 *
 * Short-circuits on the create-workspace step's failure — nothing to clean
 * up, no workspace was ever created.
 *
 * A create-ICM-stage failure (including the generation-unavailable guard) —
 * both happen AFTER the workspace already exists and the onboarding UI is
 * gone — is persisted via `deps.setPendingIcmError` (mapped through
 * `createIcmErrorMessage`, the create-specific copy table — nothing was
 * mounted, so `declareMountErrorMessage`'s "could not mount" wording would
 * misdescribe the failure) and takes the user to Knowledge. The workspace
 * itself staying open with no ICM mounted yet is non-destructive; the
 * persisted error is what keeps that from being SILENT.
 */
export async function startFresh(
  name: string,
  folder: string,
  workspaceName: string | null,
  deps: StartFreshDeps
): Promise<StartFreshOutcome> {
  const trimmedWorkspaceName = workspaceName?.trim();
  const finalWorkspaceName = trimmedWorkspaceName ? trimmedWorkspaceName : name;

  const createResult = await deps.createWorkspace(finalWorkspaceName);
  if (!createResult.ok) return { ok: false, stage: 'create-workspace', error: createResult.error };

  const generation = deps.currentGeneration();
  if (generation == null) {
    deps.setPendingIcmError(name, folder, createIcmErrorMessage('workspace_not_open'));
    deps.goToKnowledge();
    return { ok: false, stage: 'create-icm', error: 'workspace_not_open' };
  }

  const icmResult = await deps.createIcm(name, folder, generation);
  if (!icmResult.ok) {
    deps.setPendingIcmError(name, folder, createIcmErrorMessage(icmResult.error));
    deps.goToKnowledge();
    return { ok: false, stage: 'create-icm', error: icmResult.error };
  }

  deps.goToFirstSession(icmResult.mountKey);
  return { ok: true, mountKey: icmResult.mountKey };
}

// -- Task 10.3: "Use existing ICM" -------------------------------------------

/**
 * Shape of an `inspect_icm` RPC result's `data` payload (Task 10.1's
 * onboarding preview primitive — `Valea.Api.Icms.inspect_icm`, see its
 * moduledoc). Unlike `PathInspection`/`inspect_path`, this action never
 * rejects with an RPC-level error and needs no open workspace: `ok`
 * discriminates a healthy, format-2 ICM (`name`/`description` from its
 * manifest, `reason` null) from anything else (`name`/`description` null,
 * `reason` a human-readable sentence — surfaced VERBATIM in the preview UI
 * per the 10.1 flag, never remapped).
 */
export type IcmInspection = {
  ok: boolean;
  name: string | null;
  description: string | null;
  reason: string | null;
  /**
   * Task 12/13: true when `path` isn't a Valea ICM yet, but IS a plain
   * folder Valea could adopt by writing a small identity file (`icm.yaml`)
   * into it — the ONLY file the consent step (`adoptExistingIcm`/
   * `adoptExisting`) ever writes. Always `false` when `ok` is true (a
   * healthy ICM needs no adopting) and always `false` for the RPC-level
   * failure branch (`inspectIcm` returning `{ok: false, error}` — no
   * `IcmInspection` payload exists there to be adoptable).
   */
  adoptable: boolean;
};

/**
 * Dependencies `useExistingIcm` needs, injected the same way `startFresh`
 * above is — testable without a real store or RPC round trip.
 */
export type UseExistingIcmDeps = {
  /** `Valea.Api.Icms.inspect_icm` — read-only preview, no workspace needed. */
  inspectIcm: (path: string) => Promise<{ ok: true; data: IcmInspection } | { ok: false; error: string }>;
  /** `Valea.Api.Workspace.create_workspace` (id-based, app-owned — no path). */
  createWorkspace: (name: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  /** `Valea.Api.Icms.mount_icm` — mounts the ALREADY-HEALTHY folder at `path` by reference; never copies or moves it. */
  mountIcm: (path: string, generation: number) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
  /** Reads the CURRENT generation — a closure, not a value, and always called AFTER `createWorkspace` resolves. `null` means the workspace isn't open (unexpected). */
  currentGeneration: () => number | null;
  /**
   * Persists a mount-stage failure so it survives the onboarding-to-app
   * transition — same fix-wave-1 reasoning `StartFreshDeps.setPendingIcmError`
   * documents above, and wired to the SAME `mountsStore.setPendingAdoptError`
   * field: a successful "Mount a folder from elsewhere…" retry against the
   * same `path` clears it either way.
   */
  setPendingMountError: (name: string, path: string, message: string) => void;
  /** Bare navigation to Knowledge for the failure path — no mount succeeded, so there is no `mountKey` to select; the default-first-enabled-mount fallback picks something reasonable while the persisted error explains what went wrong. */
  goToKnowledge: () => void;
  /** Navigates to the newly-mounted ICM's own Knowledge view (`/knowledge?icm=<mountKey>`) on success — the sidebar's per-mount "New session" action is what makes that landing "prominent", not anything special about this navigation itself. */
  goToMountedIcm: (mountKey: string) => void;
};

export type UseExistingIcmOutcome =
  | { ok: true; mountKey: string }
  | { ok: false; stage: 'inspect' | 'create-workspace' | 'mount'; error: string }
  /**
   * Task 13: `path` isn't a healthy ICM, but IS adoptable (see
   * `IcmInspection.adoptable`'s doc comment) — nothing was created or
   * mounted. Carries the full `inspection` so the caller's consent-step UI
   * can render without a second `inspect_icm` round trip.
   */
  | { ok: false; stage: 'adoptable'; inspection: IcmInspection };

/**
 * Orchestrates "Use existing ICM" (Task 10.3): previews `path` via
 * `inspectIcm` FIRST (per spec: "we'll show you what's inside before
 * anything mounts") and blocks before creating anything when it isn't a
 * healthy, format-2 ICM — either an RPC-level failure, or `data.ok: false`
 * (surfaced via `data.reason`, a human-readable sentence — see
 * `IcmInspection`'s doc comment). Only then scaffolds a brand-new, hidden,
 * id-based workspace (`createWorkspace`) and mounts `path` into it BY
 * REFERENCE (`mountIcm`) — nothing is copied or moved; the folder stays
 * exactly where it is.
 *
 * `workspaceName` is the secondary, editable field in
 * `OpenWorkspaceFlow.svelte`'s preview card — `null`/blank falls back to the
 * ICM's own manifest name (or the folder's basename, when the manifest name
 * itself is blank), same "adjustable, defaults from the ICM name" contract
 * the brief specifies.
 *
 * Short-circuits on an inspect failure — nothing is created. Short-circuits
 * on a create-workspace failure too — nothing to clean up, no workspace was
 * ever created.
 *
 * A mount-stage failure (including the generation-unavailable guard) — both
 * happen AFTER the workspace already exists and the onboarding UI is gone —
 * is persisted via `deps.setPendingMountError` and takes the user to
 * Knowledge, same treatment `startFresh` gives its own create-ICM-stage
 * failure above.
 */
export async function useExistingIcm(
  path: string,
  workspaceName: string | null,
  deps: UseExistingIcmDeps
): Promise<UseExistingIcmOutcome> {
  const inspectResult = await deps.inspectIcm(path);
  if (!inspectResult.ok) return { ok: false, stage: 'inspect', error: inspectResult.error };

  const inspection = inspectResult.data;
  if (!inspection.ok) {
    if (inspection.adoptable) {
      return { ok: false, stage: 'adoptable', inspection };
    }
    return { ok: false, stage: 'inspect', error: inspection.reason ?? 'not_a_healthy_icm' };
  }

  const trimmedIcmName = inspection.name?.trim();
  const icmName = trimmedIcmName ? trimmedIcmName : basename(path);
  const trimmedWorkspaceName = workspaceName?.trim();
  const finalWorkspaceName = trimmedWorkspaceName ? trimmedWorkspaceName : icmName;

  const createResult = await deps.createWorkspace(finalWorkspaceName);
  if (!createResult.ok) return { ok: false, stage: 'create-workspace', error: createResult.error };

  const generation = deps.currentGeneration();
  if (generation == null) {
    deps.setPendingMountError(icmName, path, declareMountErrorMessage('workspace_not_open'));
    deps.goToKnowledge();
    return { ok: false, stage: 'mount', error: 'workspace_not_open' };
  }

  const mountResult = await deps.mountIcm(path, generation);
  if (!mountResult.ok) {
    deps.setPendingMountError(icmName, path, declareMountErrorMessage(mountResult.error));
    deps.goToKnowledge();
    return { ok: false, stage: 'mount', error: mountResult.error };
  }

  deps.goToMountedIcm(mountResult.mountKey);
  return { ok: true, mountKey: mountResult.mountKey };
}

// -- Task 13: adopt-a-folder consent step ------------------------------------

/**
 * Dependencies `adoptExistingIcm` needs — the onboarding twin of
 * `mount-icm-action.ts`'s `AdoptExistingDeps`, injected the same way
 * `UseExistingIcmDeps` above is. No `inspectIcm` here: this only ever runs
 * AFTER `useExistingIcm`'s own `inspect_icm` call already flagged the folder
 * `adoptable` (the `'adoptable'` outcome above) and the consent-step UI
 * confirmed with the user.
 */
export type AdoptExistingIcmDeps = {
  /** `Valea.Api.Workspace.create_workspace` (id-based, app-owned — no path). */
  createWorkspace: (name: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  /** `Valea.Api.Icms.adopt_icm` — mints `{format: 2, id, name}` into the folder (the one consented write), then mounts it by reference. */
  adoptIcm: (path: string, name: string, generation: number) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
  /** Reads the CURRENT generation — a closure, not a value, and always called AFTER `createWorkspace` resolves. `null` means the workspace isn't open (unexpected). */
  currentGeneration: () => number | null;
  /** Persists a mount-stage failure so it survives the onboarding-to-app transition — same `mountsStore.setPendingAdoptError` field `useExistingIcm`'s own mount-stage failure uses above. */
  setPendingMountError: (name: string, path: string, message: string) => void;
  /** Bare navigation to Knowledge for the failure path — same reasoning `UseExistingIcmDeps.goToKnowledge` documents above. */
  goToKnowledge: () => void;
  /** Navigates to the newly-adopted-and-mounted ICM's own Knowledge view on success. */
  goToMountedIcm: (mountKey: string) => void;
};

/**
 * Orchestrates the adopt-a-folder consent step (Task 13, Spec D §D4): the
 * SAME create-workspace → post-create-generation → mount-stage shape
 * `useExistingIcm` runs above, with `deps.adoptIcm(path, name, generation)`
 * — which mints the folder's identity file AND mounts it in one step — in
 * place of `deps.mountIcm(path, generation)`. `name` is the user-typed
 * field from the consent UI (defaulting to the folder's basename): unlike
 * `useExistingIcm`, there is no manifest yet to read a name from, so this
 * function never falls back to one.
 *
 * `workspaceName` keeps the same "secondary, editable, defaults from the
 * ICM name" contract `useExistingIcm`'s own parameter has — `null`/blank
 * falls back to `name` here rather than a manifest name.
 *
 * Short-circuits on a create-workspace failure — nothing to clean up, no
 * workspace was ever created. A mount-stage failure (including the
 * generation-unavailable guard) — happening AFTER the workspace already
 * exists and the onboarding UI is gone — is persisted via
 * `deps.setPendingMountError` and takes the user to Knowledge, same
 * treatment `useExistingIcm` gives its own mount-stage failure.
 */
export async function adoptExistingIcm(
  path: string,
  workspaceName: string | null,
  name: string,
  deps: AdoptExistingIcmDeps
): Promise<UseExistingIcmOutcome> {
  const trimmedWorkspaceName = workspaceName?.trim();
  const finalWorkspaceName = trimmedWorkspaceName ? trimmedWorkspaceName : name;

  const createResult = await deps.createWorkspace(finalWorkspaceName);
  if (!createResult.ok) return { ok: false, stage: 'create-workspace', error: createResult.error };

  const generation = deps.currentGeneration();
  if (generation == null) {
    deps.setPendingMountError(name, path, declareMountErrorMessage('workspace_not_open'));
    deps.goToKnowledge();
    return { ok: false, stage: 'mount', error: 'workspace_not_open' };
  }

  const adoptResult = await deps.adoptIcm(path, name, generation);
  if (!adoptResult.ok) {
    deps.setPendingMountError(name, path, declareMountErrorMessage(adoptResult.error));
    deps.goToKnowledge();
    return { ok: false, stage: 'mount', error: adoptResult.error };
  }

  deps.goToMountedIcm(adoptResult.mountKey);
  return { ok: true, mountKey: adoptResult.mountKey };
}
