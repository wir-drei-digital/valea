<script lang="ts">
  // "Start fresh" (Task 10.2): name your first ICM, confirm (or override) the
  // folder it lives in — and, in a secondary field, the workspace's own name
  // (visible later in the sidebar's workspace switcher and the welcome
  // screen's Recent list; only the workspace PATH is hidden) — and go.
  // `startFresh` (onboarding-path.ts) scaffolds the hidden workspace and
  // THEN mints the ICM at that folder; nothing else is asked of the user
  // here. Supersedes this component's earlier "guided fallback for the
  // chat-based setup assistant" incarnation — that assistant never landed,
  // and Tasks 10.2/10.3 rebuild onboarding around two direct paths instead
  // of a wizard.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { goto } from '$app/navigation';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { startFresh, defaultIcmFolder, type StartFreshDeps } from './onboarding-path';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  let name = $state('');
  let folder = $state(defaultIcmFolder(''));
  // Tracks whether the user picked/typed a folder themselves — once true,
  // `folder` stops following `name`'s live default suggestion. Same
  // touched-field convention `MountFromElsewhereDialog.svelte`'s
  // `nameEdited` uses for its own name/path pair, mirrored here for the
  // folder/name pair instead (the direction reverses: there, the picked path
  // suggests a name; here, the typed name suggests a folder).
  let folderEdited = $state(false);
  // Secondary "Workspace name" field (brief: "Workspace name defaults from
  // the ICM name, adjustable in a secondary field") — `null` (untouched)
  // renders the live ICM-name default and lets `startFresh` apply the same
  // fallback itself; once the user types, this holds their literal
  // override. Same `null`-until-edited pattern `OpenWorkspaceFlow.svelte`
  // uses for its own workspace-name field.
  let workspaceName = $state<string | null>(null);
  let submitting = $state(false);
  let error = $state<string | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  $effect(() => {
    if (open) {
      name = '';
      folder = defaultIcmFolder('');
      folderEdited = false;
      workspaceName = null;
      submitting = false;
      error = null;
    }
  });

  function onNameInput() {
    if (!folderEdited) folder = defaultIcmFolder(name);
  }

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      folder = selected;
      folderEdited = true;
    }
  }

  function onFolderInput() {
    folderEdited = true;
  }

  const deps: StartFreshDeps = {
    // `workspaceStore.create`'s `parentDir` is accepted-but-ignored
    // (app-owned, id-based create — see that method's own doc comment); no
    // caller here has a filesystem location to give it.
    createWorkspace: (n) => workspaceStore.create('', n),
    createIcm: (n, path, generation) => mountsStore.create(n, path, generation),
    currentGeneration: () => workspaceStore.generation,
    setPendingIcmError: (n, ref, message) => mountsStore.setPendingAdoptError(n, ref, message),
    goToKnowledge: () => void goto('/knowledge'),
    goToFirstSession: (mountKey) => void goto(`/chat?icm=${mountKey}`)
  };

  // `Valea.Workspace.Manager.create/1`'s (id-based) failure surface — small
  // and component-local, per this codebase's per-call-site error-copy
  // convention. Deliberately NOT `declareMountErrorMessage`: nothing was
  // mounted (or even attempted) when the WORKSPACE create fails, so "could
  // not mount that folder" would misdescribe it.
  function createWorkspaceErrorMessage(code: string): string {
    switch (code) {
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      default:
        return 'Something went wrong while creating the workspace. Try again.';
    }
  }

  async function submit() {
    error = null;

    if (!name.trim()) {
      error = 'Give it a name.';
      return;
    }
    if (!folder.trim()) {
      error = 'Choose a folder.';
      return;
    }

    submitting = true;
    const outcome = await startFresh(name.trim(), folder.trim(), workspaceName, deps);
    submitting = false;

    // A create-ICM-stage failure already flipped the workspace open and
    // navigated to Knowledge with the error persisted there (see
    // `startFresh`'s doc comment) — this card is unmounted by the time that
    // resolves, so there is nothing left here to render into. Only a
    // create-workspace-stage failure still has this dialog on screen.
    if (!outcome.ok && outcome.stage === 'create-workspace') {
      error = createWorkspaceErrorMessage(outcome.error);
      return;
    }

    if (outcome.ok) {
      open = false;
    }
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Start fresh</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        This folder is yours: plain files you can open, export, or hand off anytime. Nothing connects without
        asking you.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="fresh-icm-name">Name</Label>
        <Input
          id="fresh-icm-name"
          bind:value={name}
          oninput={onNameInput}
          disabled={submitting}
          placeholder="Coaching Practice"
        />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="fresh-icm-folder">Folder</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input id="fresh-icm-folder" bind:value={folder} disabled={submitting} readonly />
            <Button type="button" variant="outline" onclick={pickFolder} disabled={submitting}>
              Choose another location…
            </Button>
          </div>
        {:else}
          <Input id="fresh-icm-folder" bind:value={folder} oninput={onFolderInput} disabled={submitting} />
          <p class="text-ink-meta text-[11px]">Dev only: the desktop app suggests this automatically.</p>
        {/if}
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="fresh-workspace-name">Workspace name</Label>
        <Input
          id="fresh-workspace-name"
          value={workspaceName ?? name.trim()}
          oninput={(e) => (workspaceName = e.currentTarget.value)}
          disabled={submitting}
          placeholder="Coaching Practice"
        />
        <p class="text-ink-meta text-[11px]">How this shows up in the workspace switcher, usually the same name.</p>
      </div>

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button type="button" onclick={submit} disabled={submitting}>
        {submitting ? 'Setting up…' : 'Create'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
