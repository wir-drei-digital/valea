<script lang="ts">
  // Task 10.4: sidebar footer "Mount an ICM" — gives the RUNNING app (a
  // workspace is ALREADY open) the same two affordances Tasks 10.2/10.3
  // built for onboarding: "Mount an existing ICM…" (path → inspect_icm
  // preview → mount by reference) and "Create a new ICM…" (name + a visible
  // default folder → create). Unlike onboarding, there is no workspace to
  // scaffold and no post-create-generation dance — `mountExisting`/
  // `createNewIcm` (mount-icm-action.ts) skip the `createWorkspace` step
  // entirely and take the CURRENT generation as a plain, already-known
  // number.
  //
  // "Mount an existing ICM…" reuses `MountFromElsewhereDialog.svelte`
  // verbatim — Knowledge's own "Mount a folder from elsewhere…" entry point
  // — rather than a second, divergent mount dialog (brief: "prefer ONE
  // shared dialog component used from both the sidebar footer and
  // Knowledge"). "Create a new ICM…" has no onboarding counterpart to reuse
  // a dialog from (`CreateWorkspaceDialog.svelte` also scaffolds a
  // workspace, which doesn't apply here), so it gets its own small inline
  // form, modeled on that dialog minus its "Workspace name" field.
  import { goto } from '$app/navigation';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import Plus from '@lucide/svelte/icons/plus';
  import MountFromElsewhereDialog from '$lib/components/knowledge/MountFromElsewhereDialog.svelte';
  import { mountsStore, createIcmErrorMessage } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { defaultIcmFolder } from '$lib/components/onboarding/onboarding-path';
  import { createNewIcm, type CreateNewIcmDeps } from './mount-icm-action';

  let mountOpen = $state(false);
  let createOpen = $state(false);

  let name = $state('');
  let folder = $state(defaultIcmFolder(''));
  // Touched-field convention `CreateWorkspaceDialog.svelte`'s `folderEdited`
  // uses for the same name/folder pair — once true, `folder` stops
  // following `name`'s live default suggestion.
  let folderEdited = $state(false);
  let submitting = $state(false);
  let error = $state<string | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  $effect(() => {
    if (createOpen) {
      name = '';
      folder = defaultIcmFolder('');
      folderEdited = false;
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

  // `mountsStore.create` already refreshes the catalog on success (same
  // reasoning `setEnabled`/`declare` document) and returns the
  // backend-assigned `mountKey` — no need to bypass it the way
  // `MountFromElsewhereDialog`'s own `mountIcmDep` bypasses `declare`.
  const deps: CreateNewIcmDeps = {
    createIcm: (n, path, generation) => mountsStore.create(n, path, generation)
  };

  /** Lands the user on the ICM they just mounted/created — same continuation `useExistingIcm`'s `goToMountedIcm` gives onboarding. */
  function goToMounted(mountKey: string) {
    void goto(`/knowledge?icm=${encodeURIComponent(mountKey)}`);
  }

  async function submitCreate() {
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
    const outcome = await createNewIcm(name.trim(), folder.trim(), workspaceStore.generation ?? 0, deps);
    submitting = false;

    if (!outcome.ok) {
      error = createIcmErrorMessage(outcome.error);
      return;
    }

    createOpen = false;
    goToMounted(outcome.mountKey);
  }
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger>
    {#snippet child({ props })}
      <button
        type="button"
        {...props}
        class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading mt-1 flex items-center gap-1.5 rounded-md px-2 py-1.5 text-left text-[12px] transition-colors"
      >
        <Plus class="size-3" strokeWidth={1.5} aria-hidden="true" />
        Add a project
      </button>
    {/snippet}
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="start">
    <DropdownMenu.Item onSelect={() => (mountOpen = true)}>Use an existing folder…</DropdownMenu.Item>
    <DropdownMenu.Item onSelect={() => (createOpen = true)}>Create a new project…</DropdownMenu.Item>
  </DropdownMenu.Content>
</DropdownMenu.Root>

<MountFromElsewhereDialog bind:open={mountOpen} onMounted={goToMounted} />

<Dialog.Root bind:open={createOpen}>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Create a new project</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Give it a name and a folder. Valea creates a small starter knowledge module there — plain Markdown pages you
        own.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="mount-action-create-name">Name</Label>
        <Input
          id="mount-action-create-name"
          bind:value={name}
          oninput={onNameInput}
          disabled={submitting}
          placeholder="Coaching Practice"
        />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mount-action-create-folder">Folder</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input id="mount-action-create-folder" bind:value={folder} disabled={submitting} readonly />
            <Button type="button" variant="outline" onclick={pickFolder} disabled={submitting}>
              Choose another location…
            </Button>
          </div>
        {:else}
          <Input id="mount-action-create-folder" bind:value={folder} oninput={onFolderInput} disabled={submitting} />
          <p class="text-ink-meta text-[11px]">Dev only — the desktop app suggests this automatically.</p>
        {/if}
      </div>

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (createOpen = false)} disabled={submitting}>
        Cancel
      </Button>
      <Button type="button" onclick={submitCreate} disabled={submitting}>
        {submitting ? 'Creating…' : 'Create'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
