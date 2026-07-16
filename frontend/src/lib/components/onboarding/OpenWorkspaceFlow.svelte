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
  // onboarding-path.ts as of this task. `Valea.Workspace.Adopt`/
  // `inspect_path`/`adopt_workspace` stay registered on the backend (Phase
  // 11 deletes them); this component just no longer calls them.
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { basename, useExistingIcm, type IcmInspection, type UseExistingIcmDeps } from './onboarding-path';

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

  // Bypasses `mountsStore.declare` (which discards the RPC's `mountKey` —
  // it was designed for Knowledge's "Mount a folder from elsewhere…"
  // dialog, which has no post-mount navigation target to build) and calls
  // `mountIcm` directly so this flow can navigate straight to the new
  // mount's own Knowledge view. Refreshes the catalog on success, same
  // reasoning as every other mutating `MountsStore` method.
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

  function cancel() {
    path = '';
    inspection = null;
    inspectError = null;
    mountError = null;
    workspaceName = null;
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
