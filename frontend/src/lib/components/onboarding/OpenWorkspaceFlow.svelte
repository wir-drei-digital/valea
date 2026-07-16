<script lang="ts">
  // "Use existing ICM" (Task 10.3): pick a folder, preview it via
  // `inspect_icm` BEFORE anything mounts (per spec: "we'll show you what's
  // inside before anything mounts"), then — only if it's a healthy,
  // format-2 ICM — create a brand-new hidden workspace and mount that
  // folder into it BY REFERENCE (`useExistingIcm`, onboarding-path.ts).
  // Nothing is ever copied or moved; the folder stays exactly where it is.
  //
  // Supersedes this component's earlier `inspect_path`-based three-way
  // branch (open-an-existing-workspace / adopt-by-move / adopt-by-reference,
  // A-T16/A2-T9) — that whole `decideOnboardingMode` flow is gone from
  // onboarding-path.ts. `Valea.Workspace.Adopt`/`inspect_path`/
  // `adopt_workspace` are deleted from the backend entirely (Phase 11).
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import {
    adoptExistingIcm,
    basename,
    useExistingIcm,
    type AdoptExistingIcmDeps,
    type IcmInspection,
    type UseExistingIcmDeps
  } from './onboarding-path';

  let path = $state('');
  let inspecting = $state(false);
  let inspectError = $state<string | null>(null);
  let inspection = $state<IcmInspection | null>(null);

  // The preview card's editable "workspace name" field — defaults to the
  // ICM's own manifest name (or the folder's basename, when the manifest
  // name is itself blank) but stays independently editable, per the brief:
  // "the workspace name defaults from the ICM name, editable, path never
  // shown". `null` (untouched) lets `useExistingIcm` apply that fallback
  // itself; once the user types, this holds their literal override.
  let workspaceName = $state<string | null>(null);

  // Task 13: the adopt-a-folder consent step's editable "Name" field —
  // defaults to the picked folder's basename the moment an adoptable
  // inspection arrives (see `inspect()` below), stays independently
  // editable after that. Unlike `workspaceName` above, there is no
  // manifest name to fall back to (no manifest exists yet), so this holds
  // the literal value directly rather than a nullable override.
  let adoptName = $state('');

  let mounting = $state(false);
  let mountError = $state<string | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  const icmName = $derived.by(() => {
    if (!inspection || !inspection.ok) return '';
    const trimmed = inspection.name?.trim();
    return trimmed ? trimmed : basename(path);
  });

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      path = selected;
      await inspect();
    }
  }

  async function inspect() {
    inspectError = null;
    inspection = null;
    mountError = null;
    workspaceName = null;
    adoptName = '';

    const trimmedPath = path.trim();
    if (!trimmedPath) {
      inspectError = 'Choose a folder to preview.';
      return;
    }

    inspecting = true;
    const result = await api.inspectIcm(trimmedPath);
    inspecting = false;

    if (!result.ok) {
      inspectError = 'Something went wrong while reading that folder. Try again.';
      return;
    }

    inspection = result.data as IcmInspection;
    if (!inspection.ok && inspection.adoptable) {
      adoptName = basename(trimmedPath);
    }
  }

  // `api.inspectIcm`'s result already carries `{ok, name, description,
  // reason}` (the exact `IcmInspection` shape — see that type's doc
  // comment) once it's a channel/HTTP success; only the outer `data` cast
  // is needed since the generated client infers its own structural type per
  // requested field set rather than reusing this module's named type.
  async function inspectIcmDep(p: string): ReturnType<UseExistingIcmDeps['inspectIcm']> {
    const result = await api.inspectIcm(p);
    if (!result.ok) return result;
    return { ok: true, data: result.data as unknown as IcmInspection };
  }

  // Calls `mountIcm` directly (rather than a `MountsStore` wrapper) so
  // this flow can navigate straight to the new mount's own Knowledge
  // view, since the RPC's returned `mountKey` is what the navigation
  // target needs. Refreshes the catalog on success, same reasoning as
  // every other mutating `MountsStore` method.
  async function mountIcmDep(p: string, generation: number): ReturnType<UseExistingIcmDeps['mountIcm']> {
    const result = await api.mountIcm(p, generation);
    if (!result.ok) return result;
    const data = result.data as { mountKey: string; id: string };
    mountsStore.clearPendingAdoptError();
    await mountsStore.refresh();
    return { ok: true, mountKey: data.mountKey };
  }

  const deps: UseExistingIcmDeps = {
    inspectIcm: inspectIcmDep,
    // `workspaceStore.create`'s `parentDir` is accepted-but-ignored
    // (app-owned, id-based create — see that method's own doc comment).
    createWorkspace: (n) => workspaceStore.create('', n),
    mountIcm: mountIcmDep,
    currentGeneration: () => workspaceStore.generation,
    setPendingMountError: (n, ref, message) => mountsStore.setPendingAdoptError(n, ref, message),
    goToKnowledge: () => void goto('/knowledge'),
    goToMountedIcm: (mountKey) => void goto(`/knowledge?icm=${mountKey}`)
  };

  // Calls `adopt_icm` directly, same shape `mountIcmDep` above has — the one
  // consented write the adopt-a-folder consent step gates (Task 13),
  // followed by mounting in the same RPC round trip. Refreshes the catalog
  // and clears any pending adoption-error banner on success, same as
  // `mountIcmDep`.
  async function adoptIcmDep(
    p: string,
    name: string,
    generation: number
  ): ReturnType<AdoptExistingIcmDeps['adoptIcm']> {
    const result = await api.adoptIcm(p, name, generation);
    if (!result.ok) return result;
    const data = result.data as { mountKey: string; id: string };
    mountsStore.clearPendingAdoptError();
    await mountsStore.refresh();
    return { ok: true, mountKey: data.mountKey };
  }

  const adoptDeps: AdoptExistingIcmDeps = {
    createWorkspace: (n) => workspaceStore.create('', n),
    adoptIcm: adoptIcmDep,
    currentGeneration: () => workspaceStore.generation,
    setPendingMountError: (n, ref, message) => mountsStore.setPendingAdoptError(n, ref, message),
    goToKnowledge: () => void goto('/knowledge'),
    goToMountedIcm: (mountKey) => void goto(`/knowledge?icm=${mountKey}`)
  };

  // `Valea.Workspace.Manager.create/1`'s (id-based) failure surface — small
  // and component-local, same map `CreateWorkspaceDialog.svelte` keeps for
  // its own create-workspace stage (per this codebase's per-call-site
  // error-copy convention). Deliberately NOT `declareMountErrorMessage`:
  // nothing was mounted (or even attempted) when the WORKSPACE create
  // fails, so "could not mount that folder" would misdescribe it.
  function createWorkspaceErrorMessage(code: string): string {
    switch (code) {
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      default:
        return 'Something went wrong while creating the workspace. Try again.';
    }
  }

  async function confirmMount() {
    if (!inspection || !inspection.ok) return;
    mountError = null;

    mounting = true;
    const outcome = await useExistingIcm(path.trim(), workspaceName, deps);
    mounting = false;

    // A mount-stage failure already flipped the workspace open and
    // navigated to Knowledge with the error persisted there (see
    // `useExistingIcm`'s doc comment) — this card is unmounted by the time
    // that resolves. Only a create-workspace-stage failure still has this
    // card on screen to render into ("inspect" can't fail here — the
    // Confirm button only shows once `inspection.ok` is already true).
    if (!outcome.ok && outcome.stage === 'create-workspace') {
      mountError = createWorkspaceErrorMessage(outcome.error);
    }
  }

  async function submitAdopt() {
    if (!inspection || inspection.ok || !inspection.adoptable) return;
    mountError = null;

    mounting = true;
    const outcome = await adoptExistingIcm(path.trim(), workspaceName, adoptName.trim(), adoptDeps);
    mounting = false;

    // Same reasoning `confirmMount` documents above: a mount-stage failure
    // already flipped the workspace open and navigated to Knowledge with
    // the error persisted there — this card is unmounted by the time that
    // resolves. Only a create-workspace-stage failure still has this card
    // on screen to render into ("inspect"/"adoptable" can't recur here —
    // `adoptExistingIcm` never re-inspects `path`).
    if (!outcome.ok && outcome.stage === 'create-workspace') {
      mountError = createWorkspaceErrorMessage(outcome.error);
    }
  }

  function cancel() {
    path = '';
    inspection = null;
    inspectError = null;
    mountError = null;
    workspaceName = null;
    adoptName = '';
  }
</script>

<div class="flex flex-col gap-3">
  {#if inspection}
    <div class="border-paper-border bg-paper-card flex flex-col gap-3 rounded-lg border p-4">
      {#if inspection.ok}
        <div class="flex flex-col gap-1">
          <span class="text-ink-meta text-[11px] tracking-wide uppercase">Location</span>
          <p class="text-ink-meta font-mono text-[11.5px] break-all">{path}</p>
        </div>

        <div class="flex flex-col gap-1">
          <span class="text-ink-meta text-[11px] tracking-wide uppercase">Name</span>
          <p class="text-ink-heading text-[13.5px] font-semibold">{icmName}</p>
        </div>

        {#if inspection.description}
          <p class="text-ink-body text-[13px]">{inspection.description}</p>
        {/if}

        <p class="text-ink-body text-[12.5px]">
          Nothing is copied or moved — Valea reads it right where it already lives.
        </p>

        <div class="flex flex-col gap-1.5">
          <Label for="use-existing-workspace-name">Workspace name</Label>
          <Input
            id="use-existing-workspace-name"
            value={workspaceName ?? icmName}
            oninput={(e) => (workspaceName = e.currentTarget.value)}
            disabled={mounting}
          />
        </div>

        {#if mountError}
          <p role="alert" class="text-warn-ink text-[12.5px]">{mountError}</p>
        {/if}

        <div class="flex flex-wrap gap-2">
          <Button type="button" onclick={confirmMount} disabled={mounting}>
            {mounting ? 'Setting up…' : 'Use this folder'}
          </Button>
          <Button type="button" variant="outline" onclick={cancel} disabled={mounting}>Cancel</Button>
        </div>
      {:else if inspection.adoptable}
        <!-- Task 13 (Spec D §D4): the adopt-a-folder consent step — `path`
             isn't a Valea ICM yet, but IS a plain folder Valea could adopt.
             Copy is EXACT per the brief; the ONLY file this writes is the
             identity file the copy names. -->
        <div class="flex flex-col gap-2.5">
          <p class="text-ink-body text-[13px]">
            This folder isn't a Valea ICM yet. Add a small identity file (icm.yaml) so Valea can
            recognize this folder. That's the only file Valea will write.
          </p>
          <div class="flex flex-col gap-1.5">
            <Label for="adopt-name">Name</Label>
            <Input id="adopt-name" bind:value={adoptName} disabled={mounting} />
          </div>

          {#if mountError}
            <p role="alert" class="text-warn-ink text-[12.5px]">{mountError}</p>
          {/if}

          <div class="flex flex-wrap gap-2">
            <Button type="button" disabled={mounting || !adoptName.trim()} onclick={() => void submitAdopt()}>
              Add identity file &amp; mount
            </Button>
            <Button type="button" variant="outline" onclick={cancel} disabled={mounting}>
              Choose a different folder
            </Button>
          </div>
        </div>
      {:else}
        <!-- 10.1 flag: `inspection.reason` is a human-readable sentence —
             surfaced verbatim, calm styling, never remapped. -->
        <p class="text-ink-body text-[13px]">{inspection.reason}</p>
        <Button type="button" variant="outline" onclick={cancel}>Choose a different folder</Button>
      {/if}
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

  {#if inspectError}
    <p role="alert" class="text-warn-ink text-[12.5px]">{inspectError}</p>
  {/if}
</div>
