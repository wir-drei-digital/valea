// Task 10.4: pure orchestration for the sidebar's "Mount an ICM" footer
// action (`MountIcmAction.svelte`) — the RUNNING-app counterpart to Tasks
// 10.2/10.3's onboarding paths (`onboarding-path.ts`'s `startFresh`/
// `useExistingIcm`). Same shape, ONE deliberate difference throughout: a
// workspace is ALREADY open here, so there is no `createWorkspace` step and
// no post-create-generation dance — `generation` is a plain, already-known
// number the caller supplies directly, not a closure read after a create
// call resolves.
//
// `mountExisting` is shared with `MountFromElsewhereDialog.svelte`
// (Knowledge's own "Mount a folder from elsewhere…" entry point, A2-T9) —
// ONE mount-with-preview flow used from both surfaces, not two divergent
// ones (brief: "prefer ONE shared dialog component used from both the
// sidebar footer and Knowledge").
import type { IcmInspection } from '$lib/components/onboarding/onboarding-path';

export type { IcmInspection };

/** Dependencies `mountExisting` needs, injected the same way `useExistingIcm` (onboarding-path.ts) is — testable without a real store or RPC round trip. */
export type MountExistingDeps = {
  /** `Valea.Api.Icms.inspect_icm` — read-only preview, no workspace needed. */
  inspectIcm: (path: string) => Promise<{ ok: true; data: IcmInspection } | { ok: false; error: string }>;
  /** `Valea.Api.Icms.mount_icm` — mounts the ALREADY-HEALTHY folder at `path` by reference; never copies or moves it. */
  mountIcm: (path: string, generation: number) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
};

export type MountExistingOutcome =
  | { ok: true; mountKey: string }
  | { ok: false; stage: 'inspect' | 'mount'; error: string };

/**
 * Orchestrates "Mount an existing ICM…" for an already-open workspace:
 * previews `path` via `inspectIcm` FIRST (same "we'll show you what's
 * inside before anything mounts" contract `useExistingIcm` documents) and
 * blocks before mounting anything when it isn't a healthy, format-2 ICM —
 * either an RPC-level failure, or `data.ok: false` (surfaced via
 * `data.reason`, a human-readable sentence — see `IcmInspection`'s doc
 * comment in onboarding-path.ts). Only then mounts `path` BY REFERENCE
 * (`mountIcm`) — nothing is copied or moved; the folder stays exactly where
 * it is.
 *
 * Short-circuits on an inspect failure — nothing is mounted. Unlike
 * `useExistingIcm`, a failure at either stage is returned to the caller for
 * INLINE handling (no `setPendingXError`/`goToKnowledge` — there is no
 * workspace-transition screen swap to survive here; the dialog calling this
 * just stays open and shows the error).
 */
export async function mountExisting(
  path: string,
  generation: number,
  deps: MountExistingDeps
): Promise<MountExistingOutcome> {
  const inspectResult = await deps.inspectIcm(path);
  if (!inspectResult.ok) return { ok: false, stage: 'inspect', error: inspectResult.error };

  const inspection = inspectResult.data;
  if (!inspection.ok) {
    return { ok: false, stage: 'inspect', error: inspection.reason ?? 'not_a_healthy_icm' };
  }

  const mountResult = await deps.mountIcm(path, generation);
  if (!mountResult.ok) return { ok: false, stage: 'mount', error: mountResult.error };

  return { ok: true, mountKey: mountResult.mountKey };
}

/** Dependencies `createNewIcm` needs, injected the same way `mountExisting` above is. */
export type CreateNewIcmDeps = {
  /** `Valea.Api.Icms.create_icm` — mints a brand-new ICM at `folder` (seeding the portable template) and mounts it. */
  createIcm: (
    name: string,
    folder: string,
    generation: number
  ) => Promise<{ ok: true; mountKey: string } | { ok: false; error: string }>;
};

export type CreateNewIcmOutcome = { ok: true; mountKey: string } | { ok: false; error: string };

/**
 * Orchestrates "Create a new ICM…" for an already-open workspace: mints a
 * brand-new ICM at `folder` and mounts it — the same `createIcm` step
 * `startFresh` (onboarding-path.ts) runs, minus its `createWorkspace` step.
 * No preview stage: unlike mounting an existing folder, there is nothing on
 * disk yet worth inspecting first — Valea never creates ICM content under
 * the hidden workspace itself; the ICM always lives at the user-chosen
 * `folder`.
 */
export async function createNewIcm(
  name: string,
  folder: string,
  generation: number,
  deps: CreateNewIcmDeps
): Promise<CreateNewIcmOutcome> {
  const result = await deps.createIcm(name, folder, generation);
  if (!result.ok) return { ok: false, error: result.error };
  return { ok: true, mountKey: result.mountKey };
}
