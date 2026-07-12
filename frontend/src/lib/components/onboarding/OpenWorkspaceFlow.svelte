<script lang="ts">
  // "Choose folder…" flow for the Continue card: pick a path, classify it
  // before doing anything (per spec: "we'll show you what's inside before
  // anything runs"), then branch three ways per `decideOnboardingMode`
  // (`./onboarding-path.ts`):
  //   - kind "workspace" -> the original "inspect then open" step.
  //   - kind "other" -> the original "doesn't look like a Valea workspace"
  //     error, unchanged.
  //   - kind "icm" (A-T16, ICM-aware onboarding) -> a move-consent step:
  //     the folder is NOT a workspace, but is/contains an adoptable
  //     knowledge module (`icm.yaml`). Offers "create a workspace around
  //     this knowledge module", showing the ORIGINAL path and moving
  //     (never copying — see `Valea.Workspace.Adopt`'s moduledoc) the
  //     folder into the new workspace's `mounts/`.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { decideOnboardingMode, dirname, type OnboardingMode } from './onboarding-path';

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
  // `decideOnboardingMode` but stay editable — `name` in particular MUST
  // end up different from the source folder's own name (the new
  // workspace can't be scaffolded AT the source path; see
  // `Valea.Workspace.Adopt`'s `:cycle` rejection when it isn't).
  let adopt = $state<AdoptStep | null>(null);
  let adopting = $state(false);
  let adoptError = $state<string | null>(null);

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
      case 'target_not_empty':
        return 'That folder already has files in it. Pick an empty spot for the new workspace.';
      case 'cross_device':
        return 'Keep the knowledge folder on the same disk as the new workspace for now.';
      case 'source_not_found':
        return 'That folder no longer exists.';
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
        Valea will MOVE this folder into the new workspace's <code class="font-mono text-[11.5px]">mounts/</code> —
        nothing is copied, and nothing is left behind at the original location.
      </p>

      <div class="flex flex-col gap-1.5">
        <Label for="adopt-name">Workspace name</Label>
        <Input id="adopt-name" bind:value={adopt.name} disabled={adopting} placeholder="My business" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="adopt-parent-dir">Create the workspace in</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input id="adopt-parent-dir" bind:value={adopt.parentDir} disabled={adopting} readonly />
            <Button type="button" variant="outline" onclick={pickAdoptParentFolder} disabled={adopting}>
              Browse…
            </Button>
          </div>
        {:else}
          <Input id="adopt-parent-dir" bind:value={adopt.parentDir} disabled={adopting} />
        {/if}
      </div>

      {#if adoptError}
        <p role="alert" class="text-warn-ink text-[12.5px]">{adoptError}</p>
      {/if}

      <div class="flex flex-wrap gap-2">
        <Button type="button" onclick={confirmAdopt} disabled={adopting}>
          {adopting ? 'Creating…' : 'Create a workspace around this knowledge module'}
        </Button>
        <Button type="button" variant="outline" onclick={cancel} disabled={adopting}>Cancel</Button>
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
