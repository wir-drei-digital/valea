<script lang="ts">
  // "Choose folder…" flow for the Continue card: pick a path, classify it
  // before doing anything (per spec: "we'll show you what's inside before
  // anything runs"), then branch three ways per `decideOnboardingMode`
  // (`./onboarding-path.ts`):
  //   - kind "workspace" -> the original "inspect then open" step.
  //   - kind "other" -> the original "doesn't look like a Valea workspace"
  //     error, unchanged.
  //   - kind "icm" (A-T16, ICM-aware onboarding; A2-T9, by-reference) -> a
  //     consent step offering TWO actions on the SAME source path:
  //       - "Use it where it is" (PRIMARY/default per `defaultAdoptAction`,
  //         A2-T9) — declares the folder as a by-reference mount into a
  //         BRAND-NEW workspace (`confirmReference` -> `adoptByReference`).
  //         Nothing moves; the folder never leaves its original location.
  //       - "Move it into the workspace" (secondary, unchanged A-T16
  //         behavior) — moves (never copies — see `Valea.Workspace.Adopt`'s
  //         moduledoc) the folder into the new workspace's `mounts/`.
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import {
    adoptByReference,
    basename,
    decideOnboardingMode,
    dirname,
    slugify,
    type OnboardingMode
  } from './onboarding-path';

  type Inspection = {
    valid: boolean;
    icm_pages: number;
    workflows: number;
    queue_pending: number;
    has_audit_log: boolean;
  };

  type AdoptStep = {
    originalPath: string;
    name: string;
    parentDir: string;
    description: string | null;
  };

  let path = $state('');
  let inspecting = $state(false);
  let opening = $state(false);
  let error = $state<string | null>(null);
  let inspection = $state<Inspection | null>(null);

  // ICM-aware onboarding (A-T16). `name`/`parentDir` prefill from
  // `decideOnboardingMode` but stay editable — the default config is
  // guaranteed collision-free (`decideOnboardingMode` appends " Workspace"
  // when the name would make target == source), and if the user edits it
  // back into a collision, the backend's `:target_is_source` /
  // `:target_not_empty` / `:cycle` rejections catch it with a clear error.
  let adopt = $state<AdoptStep | null>(null);
  let adopting = $state(false);
  let adoptError = $state<string | null>(null);

  // A2-T9: "Use it where it is" — the by-reference sibling of the move flow
  // above, sharing the SAME `adopt` state (source path, target workspace
  // name/parent). Kept in separate state from `adopting`/`adoptError` since
  // the two actions can't run concurrently but DO have distinct in-flight
  // labels and error vocabularies (`adoptByReference`'s two stages map
  // through different code tables — `mapCreateErrorCode` for a "create"
  // failure, `declareMountErrorMessage` for a "declare" one, see
  // `confirmReference` below).
  let referenceAdopting = $state(false);
  let referenceError = $state<string | null>(null);

  // Resolved destination, live as name/parentDir are edited: the workspace
  // that will be created, and the exact `mounts/<slug>` inside it the
  // folder will move into (slug recomputed the same way the backend does —
  // from the SOURCE folder's basename, not the workspace name). Shown on
  // the consent card so a collision or a wrong-location pick is visible
  // before clicking, not after a backend rejection.
  const adoptTargetPath = $derived(
    adopt ? `${adopt.parentDir.trim().replace(/\/+$/, '')}/${adopt.name.trim()}` : ''
  );
  const adoptMountPath = $derived(
    adopt ? `${adoptTargetPath}/mounts/${slugify(basename(adopt.originalPath))}` : ''
  );

  // A2-T9: the by-reference mount's name inside the NEW workspace — the
  // source folder's own basename, same default `MountFromElsewhereDialog`
  // uses for Knowledge's "Mount a folder from elsewhere…" flow. Not
  // separately editable here (unlike the workspace name/parent above) —
  // keeps the consent card to the two fields that actually need a
  // decision; `declare_mount`'s `invalid_mount_name` rejection (surfaced
  // via `declareMountErrorMessage`) is the backstop for a pathological
  // basename.
  const referenceMountName = $derived(adopt ? basename(adopt.originalPath) : '');

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      path = selected;
      await inspect();
    }
  }

  async function inspect() {
    error = null;
    inspection = null;
    adopt = null;
    adoptError = null;
    referenceError = null;
    if (!path.trim()) {
      error = 'Choose a folder to open.';
      return;
    }

    const trimmedPath = path.trim();
    inspecting = true;
    const result = await api.inspectPath(trimmedPath);

    if (!result.ok) {
      inspecting = false;
      error = "This folder doesn't look like a Valea workspace.";
      return;
    }

    await applyMode(decideOnboardingMode(result.data, trimmedPath), trimmedPath);
  }

  async function applyMode(mode: OnboardingMode, trimmedPath: string) {
    if (mode.mode === 'unsupported') {
      inspecting = false;
      error = "This folder doesn't look like a Valea workspace.";
      return;
    }

    if (mode.mode === 'adopt') {
      inspecting = false;
      adopt = {
        originalPath: mode.originalPath,
        name: mode.suggestedName,
        parentDir: dirname(mode.originalPath),
        description: mode.description
      };
      return;
    }

    // mode.mode === 'open' — same detailed-summary step as before this task.
    const summary = await api.inspectWorkspace(trimmedPath);
    inspecting = false;

    if (!summary.ok || !(summary.data as Inspection).valid) {
      error = "This folder doesn't look like a Valea workspace.";
      return;
    }

    inspection = summary.data as Inspection;
  }

  async function confirmOpen() {
    opening = true;
    const result = await workspaceStore.open(path.trim());
    opening = false;

    if (!result.ok) {
      error = "Couldn't open this workspace. Try again.";
      inspection = null;
      return;
    }
  }

  function mapAdoptErrorCode(code: string): string {
    switch (code) {
      case 'source_is_workspace':
      case 'source_is_open_workspace':
        return 'That folder is already a Valea workspace.';
      case 'source_in_workspace':
        return 'That folder is already part of another Valea workspace.';
      case 'cycle':
        return "The new workspace can't be created inside the knowledge folder itself. Choose a different name or location.";
      case 'target_is_source':
        return 'The new workspace would be the knowledge folder itself. Choose a different name or location.';
      case 'target_not_empty':
        return 'That folder already has files in it. Pick an empty spot for the new workspace.';
      case 'cross_device':
        return 'Keep the knowledge folder on the same disk as the new workspace for now.';
      case 'source_not_found':
        return 'That folder no longer exists.';
      case 'move_failed':
        return "The folder couldn't be moved — it's untouched at its original location. Try again.";
      default:
        return 'Something went wrong while adopting this folder. Try again.';
    }
  }

  async function confirmAdopt() {
    if (!adopt) return;
    adoptError = null;

    if (!adopt.name.trim()) {
      adoptError = 'Give the workspace a name.';
      return;
    }
    if (!adopt.parentDir.trim()) {
      adoptError = 'Choose a folder to create the workspace in.';
      return;
    }

    adopting = true;
    const result = await workspaceStore.adopt(adopt.parentDir.trim(), adopt.name.trim(), adopt.originalPath);
    adopting = false;

    if (!result.ok) {
      adoptError = mapAdoptErrorCode(result.error);
      return;
    }
  }

  // `Valea.Workspace.Manager.create/2`'s error vocabulary — same two codes
  // `CreateWorkspaceDialog.svelte`'s own (unshared, per that component's
  // precedent) `mapErrorCode` maps for the "Start fresh" flow; this is the
  // `adoptByReference` orchestration's "create" stage.
  function mapCreateErrorCode(code: string): string {
    switch (code) {
      case 'target_not_empty':
        return 'That folder already has files in it. Pick an empty spot for the new workspace.';
      case 'not_a_workspace':
        return "This folder doesn't look like a Valea workspace.";
      default:
        return 'Something went wrong while creating the workspace. Try again.';
    }
  }

  async function confirmReference() {
    if (!adopt) return;
    referenceError = null;

    if (!adopt.name.trim()) {
      referenceError = 'Give the workspace a name.';
      return;
    }
    if (!adopt.parentDir.trim()) {
      referenceError = 'Choose a folder to create the workspace in.';
      return;
    }

    referenceAdopting = true;
    const outcome = await adoptByReference(
      adopt.parentDir.trim(),
      adopt.name.trim(),
      referenceMountName,
      adopt.originalPath,
      {
        createWorkspace: (parentDir, name) => workspaceStore.create(parentDir, name),
        declareMount: (name, ref, generation) => mountsStore.declare(name, ref, generation),
        currentGeneration: () => workspaceStore.generation,
        // Declare-stage failures land AFTER workspaceStore.create flipped
        // state to 'open' — this component is unmounted by then (the root
        // layout swaps Onboarding out reactively), so any local error state
        // set at that point is a dead write. The store field survives the
        // transition; the Knowledge page renders it as a dismissible banner
        // (fix wave 1) — and the user is taken THERE rather than Today,
        // where the banner (and its retry affordance) would be out of sight
        // (fix wave 2).
        setPendingAdoptError: (name, ref, message) => mountsStore.setPendingAdoptError(name, ref, message),
        goToKnowledge: () => void goto('/knowledge')
      }
    );
    referenceAdopting = false;

    // Only a CREATE-stage failure still has this card on screen to render
    // into (the workspace never opened, so the state flip never happened).
    // A declare-stage failure was already persisted via setPendingAdoptError
    // above — setting referenceError for it would be a no-op nobody sees.
    if (!outcome.ok && outcome.stage === 'create') {
      referenceError = mapCreateErrorCode(outcome.error);
      return;
    }
  }

  async function pickAdoptParentFolder() {
    if (!adopt) return;
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      adopt.parentDir = selected;
    }
  }

  function cancel() {
    inspection = null;
    adopt = null;
    error = null;
    adoptError = null;
    referenceError = null;
  }
</script>

<div class="flex flex-col gap-3">
  {#if adopt}
    <div class="border-paper-border bg-paper-card flex flex-col gap-3 rounded-lg border p-4">
      <p class="text-ink-body text-[13px]">
        This looks like a knowledge folder, not a Valea workspace yet{#if adopt.description}
          — {adopt.description}{/if}.
      </p>

      <div class="flex flex-col gap-1">
        <span class="text-ink-meta text-[11px] tracking-wide uppercase">Original location</span>
        <p class="text-ink-meta font-mono text-[11.5px] break-all">{adopt.originalPath}</p>
      </div>

      <p class="text-ink-body text-[12.5px]">
        By default, Valea reads it right where it is — nothing moves. You can also move it into the new
        workspace's <code class="font-mono text-[11.5px]">mounts/</code> instead; either way, nothing is ever
        copied.
      </p>

      <div class="flex flex-col gap-1.5">
        <Label for="adopt-name">Workspace name</Label>
        <Input
          id="adopt-name"
          bind:value={adopt.name}
          disabled={adopting || referenceAdopting}
          placeholder="My business"
        />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="adopt-parent-dir">Create the workspace in</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input id="adopt-parent-dir" bind:value={adopt.parentDir} disabled={adopting || referenceAdopting} readonly />
            <Button
              type="button"
              variant="outline"
              onclick={pickAdoptParentFolder}
              disabled={adopting || referenceAdopting}
            >
              Browse…
            </Button>
          </div>
        {:else}
          <Input id="adopt-parent-dir" bind:value={adopt.parentDir} disabled={adopting || referenceAdopting} />
        {/if}
      </div>

      <div class="flex flex-col gap-1">
        <span class="text-ink-meta text-[11px] tracking-wide uppercase">New workspace</span>
        <p class="text-ink-meta font-mono text-[11.5px] break-all">{adoptTargetPath}</p>
        <span class="text-ink-meta text-[11px] tracking-wide uppercase">Mounted here as (stays in place)</span>
        <p class="text-ink-meta font-mono text-[11.5px] break-all">{referenceMountName}</p>
        <span class="text-ink-meta text-[11px] tracking-wide uppercase">Or, if moved instead</span>
        <p class="text-ink-meta font-mono text-[11.5px] break-all">{adoptMountPath}</p>
      </div>

      {#if referenceError}
        <p role="alert" class="text-warn-ink text-[12.5px]">{referenceError}</p>
      {/if}
      {#if adoptError}
        <p role="alert" class="text-warn-ink text-[12.5px]">{adoptError}</p>
      {/if}

      <div class="flex flex-wrap gap-2">
        <Button type="button" onclick={confirmReference} disabled={adopting || referenceAdopting}>
          {referenceAdopting ? 'Setting up…' : 'Use it where it is'}
        </Button>
        <Button
          type="button"
          variant="outline"
          onclick={confirmAdopt}
          disabled={adopting || referenceAdopting}
        >
          {adopting ? 'Moving…' : 'Move it into the workspace'}
        </Button>
        <Button type="button" variant="outline" onclick={cancel} disabled={adopting || referenceAdopting}>
          Cancel
        </Button>
      </div>
    </div>
  {:else if inspection}
    <div class="border-paper-border bg-paper-card flex flex-col gap-3 rounded-lg border p-4">
      <p class="text-ink-meta font-mono text-[11.5px]">{path}</p>
      <p class="text-ink-body text-[13px]">
        {inspection.icm_pages} memory pages · {inspection.workflows} workflows · {inspection.queue_pending} pending approvals
        · audit log {inspection.has_audit_log ? 'present' : 'missing'}
      </p>
      <div class="flex gap-2">
        <Button type="button" onclick={confirmOpen} disabled={opening}>
          {opening ? 'Opening…' : 'Open'}
        </Button>
        <Button type="button" variant="outline" onclick={cancel} disabled={opening}>Cancel</Button>
      </div>
    </div>
  {:else if isTauri}
    <Button type="button" variant="outline" onclick={pickFolder} disabled={inspecting}>
      {inspecting ? 'Checking…' : 'Choose folder…'}
    </Button>
  {:else}
    <div class="flex gap-2">
      <Input bind:value={path} disabled={inspecting} placeholder="/Users/you/Documents/my-business" />
      <Button type="button" variant="outline" onclick={inspect} disabled={inspecting}>
        {inspecting ? 'Checking…' : 'Choose folder…'}
      </Button>
    </div>
  {/if}

  {#if error}
    <p role="alert" class="text-warn-ink text-[12.5px]">{error}</p>
  {/if}
</div>
