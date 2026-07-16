// Pure branch-decision logic for the open/create dialog's ICM-aware
// onboarding: given an `inspect_path` RPC result (see
// `Valea.Workspace.Adopt.classify_path/1` on the backend) and the raw path
// the user picked, decides which of the three UI modes `OpenWorkspaceFlow`
// should show. Kept pure and separate from the component so the branch
// decision — the part most worth getting exactly right — is testable
// without mounting Svelte.
import type { PathInspection } from '$lib/api/client';
// Value import (not type-only) — `adoptByReference` maps a declare-stage
// failure to readable copy at the moment it persists it, since this is the
// one place holding name/ref/code together. Importing the pure function
// from the store module doesn't drag any Svelte runtime in at test time
// (mounts.svelte.ts is already imported directly by its own vitest suite).
import { declareMountErrorMessage } from '$lib/stores/mounts.svelte';

export type OnboardingMode =
  | { mode: 'open' }
  | { mode: 'adopt'; originalPath: string; suggestedName: string; description: string | null }
  | { mode: 'unsupported' };

/**
 * `kind: "workspace"` -> the existing "inspect then open" path.
 * `kind: "other"` -> the existing "doesn't look like a Valea workspace"
 * error — unchanged from before this task.
 * `kind: "icm"` -> the new adopt-by-move consent step. `originalPath` is
 * the EXACT path the user picked (not re-derived or normalized) — the
 * consent step shows this verbatim so the user can verify what's about to
 * move. `suggestedName` prefills the new workspace's name field: the
 * manifest's own `name` when it's a real (non-blank) string, otherwise the
 * source folder's own basename.
 *
 * Collision guard: the consent step also prefills `parentDir` with the
 * source's own parent (`dirname(originalPath)`), so a suggested name equal
 * to the source folder's basename would make the default TARGET path the
 * source itself — the backend rejects that (`:target_is_source`), but the
 * default configuration must never be a rejected one. When the candidate
 * name matches the basename ("Client Notes" inside `.../Client Notes` —
 * the common case, since adopted manifests are often named after their
 * folder), " Workspace" is appended: "Client Notes Workspace". The
 * basename-fallback case always gets this adjustment, by construction.
 */
export function decideOnboardingMode(inspection: PathInspection, path: string): OnboardingMode {
  switch (inspection.kind) {
    case 'workspace':
      return { mode: 'open' };

    case 'other':
      return { mode: 'unsupported' };

    case 'icm': {
      const trimmedName = inspection.name?.trim();
      const candidate = trimmedName ? trimmedName : basename(path);
      const suggestedName = candidate === basename(path) ? `${candidate} Workspace` : candidate;
      return {
        mode: 'adopt',
        originalPath: path,
        suggestedName,
        description: inspection.description
      };
    }
  }
}

/** Last path segment, ignoring a trailing slash. POSIX paths only (macOS/Linux). */
export function basename(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx === -1 ? trimmed : trimmed.slice(idx + 1);
}

/**
 * Parent directory, ignoring a trailing slash — used to prefill the adopt
 * dialog's default parent folder (the source's own parent, since the new
 * workspace can't be scaffolded AT the source path itself). Returns "/"
 * for a top-level path or the root path itself.
 */
export function dirname(path: string): string {
  const trimmed = path.replace(/\/+$/, '');
  const idx = trimmed.lastIndexOf('/');
  return idx <= 0 ? '/' : trimmed.slice(0, idx);
}

/**
 * Mirrors `Valea.Workspace.Scaffold.slugify/1` exactly (lowercase, NFD
 * ascii-fold stripping non-spacing marks, non-alphanumeric runs collapsed
 * to a single `-`, leading/trailing `-` trimmed, "mount" fallback) — used
 * only for DISPLAY: the consent card shows the `mounts/<slug>` destination
 * the backend will move the folder into. The backend recomputes the slug
 * itself from the source basename; this never feeds a filesystem path.
 */
export function slugify(name: string): string {
  const slug = name
    .normalize('NFD')
    .replace(/\p{Mn}/gu, '')
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, '-')
    .replace(/^-+|-+$/g, '');
  return slug === '' ? 'mount' : slug;
}

// -- A2-T9: adopt-by-reference is now the DEFAULT --------------------------

export type AdoptAction = 'reference' | 'move';

/**
 * Which adopt action gets the primary/emphasized button on the consent
 * card — the single source of truth `OpenWorkspaceFlow.svelte` reads for
 * button order/emphasis, so "reference is the default" is an assertion
 * this test file can check directly rather than something only visible by
 * reading template markup. `null` for any non-"adopt" mode (nothing to
 * default: "open" and "unsupported" have no adopt buttons at all).
 *
 * Per the Plan A2 design decision: pointing the open dialog at an ICM now
 * offers "Use it where it is" (declare `kind: "path"` — see
 * `adoptByReference` below) FIRST; "Move it into the workspace" (the
 * original A-T16 move-adopt flow, `workspaceStore.adopt`) stays available
 * as the explicit secondary choice, never removed — some folders genuinely
 * should move (a handoff, a backup import), so reference isn't a
 * replacement, just the safer/more-reversible default.
 */
export function defaultAdoptAction(mode: OnboardingMode): AdoptAction | null {
  return mode.mode === 'adopt' ? 'reference' : null;
}

export type ReferenceAdoptDeps = {
  createWorkspace: (parentDir: string, name: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  declareMount: (
    name: string,
    ref: string,
    generation: number
  ) => Promise<{ ok: true } | { ok: false; error: string }>;
  /**
   * Reads the CURRENT generation — a closure, not a value, and always
   * called AFTER `createWorkspace` resolves (mirrors `mail-shapes.ts`'s
   * `refreshWorkspaceId`): the only generation this function can trust is
   * the freshly-created workspace's own, never one the caller cached
   * beforehand. `null` means the workspace isn't open (unexpected — surfaces
   * as `workspace_not_open` on the declare stage rather than calling
   * `declareMount` with a bogus generation).
   */
  currentGeneration: () => number | null;
  /**
   * Persists a DECLARE-stage failure so it survives the onboarding-to-app
   * transition (fix wave 1): a successful `createWorkspace` flips
   * `workspaceStore.state` to `'open'`, the root layout reactively swaps
   * the Onboarding screen out, and any component-local error state set
   * after that point is a write to a dead component. Called with the
   * already-MAPPED readable message (`declareMountErrorMessage`) — this
   * function is the one place holding all three of name/ref/code together.
   * Wired to `mountsStore.setPendingAdoptError`; the Knowledge page renders
   * it as a dismissible banner. NEVER called for a create-stage failure —
   * that happens before the state flip, while the onboarding card is still
   * mounted and rendering its own `referenceError`.
   */
  setPendingAdoptError: (name: string, ref: string, message: string) => void;
  /**
   * Navigates to the Knowledge page — the surface that renders
   * `pendingAdoptError`'s banner and hosts the "Mount a folder from
   * elsewhere…" retry affordance (fix wave 2). Called ONLY on the two
   * declare-stage failure paths, right after `setPendingAdoptError`:
   * post-onboarding the user otherwise lands on Today (`/`), where the
   * banner never renders, leaving the persisted error unreachable in
   * practice. Safe to navigate at that point — the workspace state flip
   * already happened, so the route exists. Success keeps landing on Today
   * as before (no forced navigation), and a create-stage failure never
   * navigates (the onboarding screen is still up, rendering its own
   * error). Wired to SvelteKit's `goto('/knowledge')` by
   * `OpenWorkspaceFlow.svelte`; injected so this stays testable without
   * SvelteKit's runtime.
   */
  goToKnowledge: () => void;
};

export type ReferenceAdoptOutcome = { ok: true } | { ok: false; stage: 'create' | 'declare'; error: string };

/**
 * Orchestrates "Use it where it is": scaffolds a brand-new workspace the
 * NORMAL way (`createWorkspace` — starter mount included, same as "Start
 * fresh"; deliberately NOT an empty-shell workspace, per the Plan A2
 * design decision — the starter mount is the workspace's own knowledge
 * home, and the external ICM arrives as a SECOND, referenced mount
 * alongside it, not a replacement for it), then declares the external
 * folder into it as a by-reference mount (`mountName`/`icmSourcePath` ->
 * `declareMount`).
 *
 * There is no backend "adopt by reference" endpoint — `Valea.Workspace.Adopt`
 * is move-only (see its moduledoc) — so this frontend-side sequencing IS
 * the by-reference adoption path; keeping it here (pure, deps-injected)
 * rather than inline in the component is what makes it testable without a
 * real store or RPC round trip.
 *
 * Short-circuits on the create step's failure — nothing to clean up, since
 * no mount was ever declared and no workspace-scoped mutation happened
 * beyond the (now-existing but reference-less) new workspace itself, which
 * the user can just retry into or abandon.
 *
 * A declare-stage failure (including the generation-unavailable guard —
 * both happen after the create already succeeded and the onboarding UI is
 * gone) is additionally persisted via `deps.setPendingAdoptError` — see
 * that dep's doc comment. The workspace itself staying open with the mount
 * not declared is fine and non-destructive; the persisted error is what
 * keeps it from being SILENT.
 */
export async function adoptByReference(
  parentDir: string,
  workspaceName: string,
  mountName: string,
  icmSourcePath: string,
  deps: ReferenceAdoptDeps
): Promise<ReferenceAdoptOutcome> {
  const createResult = await deps.createWorkspace(parentDir, workspaceName);
  if (!createResult.ok) return { ok: false, stage: 'create', error: createResult.error };

  const generation = deps.currentGeneration();
  if (generation == null) {
    deps.setPendingAdoptError(mountName, icmSourcePath, declareMountErrorMessage('workspace_not_open'));
    deps.goToKnowledge();
    return { ok: false, stage: 'declare', error: 'workspace_not_open' };
  }

  const declareResult = await deps.declareMount(mountName, icmSourcePath, generation);
  if (!declareResult.ok) {
    deps.setPendingAdoptError(mountName, icmSourcePath, declareMountErrorMessage(declareResult.error));
    deps.goToKnowledge();
    return { ok: false, stage: 'declare', error: declareResult.error };
  }

  return { ok: true };
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
 * Dependencies `startFresh` needs, injected the same way `adoptByReference`
 * above is — testable without a real store or RPC round trip.
 */
export type StartFreshDeps = {
  /** `Valea.Api.Workspace.create_workspace` (id-based, app-owned — no path). */
  createWorkspace: (name: string) => Promise<{ ok: true } | { ok: false; error: string }>;
  /**
   * `Valea.Api.Icms.create_icm` — mints a brand-new ICM at `folder` (seeding
   * the portable template) and mounts it. Reads the CURRENT generation via
   * `currentGeneration`, same post-create-only-trusted rule
   * `ReferenceAdoptDeps.currentGeneration` documents above.
   */
  createIcm: (
    name: string,
    folder: string,
    generation: number
  ) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
  /** Reads the CURRENT generation — see `ReferenceAdoptDeps.currentGeneration` above for why this is a closure, not a value, and always called AFTER `createWorkspace` resolves. */
  currentGeneration: () => number | null;
  /**
   * Persists a create-ICM-stage failure so it survives the onboarding-to-app
   * transition, same fix-wave-1 reasoning `ReferenceAdoptDeps.setPendingAdoptError`
   * documents: `createWorkspace` already flipped `workspaceStore.state` to
   * 'open' by the time this can fail, unmounting the onboarding card that
   * would otherwise render a local error. Wired to the SAME
   * `mountsStore.setPendingAdoptError` field `adoptByReference` uses — a
   * successful "Mount a folder from elsewhere…" retry against the same
   * `folder` clears it either way, and `createIcm` may have already written
   * a healthy `icm.yaml` to `folder` before the mount step itself failed,
   * making that retry path a real recovery, not a dead end.
   */
  setPendingIcmError: (name: string, folder: string, message: string) => void;
  /** Navigates to Knowledge — the surface that renders the persisted error, same reasoning as `ReferenceAdoptDeps.goToKnowledge`. */
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
 * `folder`. `name` is shared by both calls: the ICM's display name doubles
 * as the workspace's own internal display name (the workspace's id/path are
 * never shown to the user, so there is nothing for a second name to
 * disambiguate).
 *
 * Short-circuits on the create-workspace step's failure — nothing to clean
 * up, no workspace was ever created (mirrors `adoptByReference`'s own
 * create-stage short-circuit).
 *
 * A create-ICM-stage failure (including the generation-unavailable guard) —
 * both happen AFTER the workspace already exists and the onboarding UI is
 * gone — is persisted via `deps.setPendingIcmError` and takes the user to
 * Knowledge, same fix-wave-1/2 treatment `adoptByReference` gives its own
 * declare-stage failure. The workspace itself staying open with no ICM
 * mounted yet is non-destructive; the persisted error is what keeps that
 * from being SILENT.
 */
export async function startFresh(name: string, folder: string, deps: StartFreshDeps): Promise<StartFreshOutcome> {
  const createResult = await deps.createWorkspace(name);
  if (!createResult.ok) return { ok: false, stage: 'create-workspace', error: createResult.error };

  const generation = deps.currentGeneration();
  if (generation == null) {
    deps.setPendingIcmError(name, folder, declareMountErrorMessage('workspace_not_open'));
    deps.goToKnowledge();
    return { ok: false, stage: 'create-icm', error: 'workspace_not_open' };
  }

  const icmResult = await deps.createIcm(name, folder, generation);
  if (!icmResult.ok) {
    deps.setPendingIcmError(name, folder, declareMountErrorMessage(icmResult.error));
    deps.goToKnowledge();
    return { ok: false, stage: 'create-icm', error: icmResult.error };
  }

  deps.goToFirstSession(icmResult.mountKey);
  return { ok: true, mountKey: icmResult.mountKey };
}
