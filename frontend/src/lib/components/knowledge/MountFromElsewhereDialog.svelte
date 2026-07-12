<script lang="ts">
  // "Mount a folder from elsewhere…" (A2-T9) — Knowledge's by-reference
  // counterpart to `NewEntryDialog`'s "New page/folder": picks an EXTERNAL
  // folder (Tauri directory picker; browser-dev falls back to a text input,
  // same pattern `OpenWorkspaceFlow.svelte` already uses) and declares it
  // as a mount via `mountsStore.declare` — nothing is copied or moved, the
  // folder is read exactly where it already lives.
  //
  // `name` defaults to the picked folder's own basename (editable) — same
  // default `OpenWorkspaceFlow`'s onboarding "Use it where it is" flow uses
  // for its (non-editable, there) mount name.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { mountsStore, declareMountErrorMessage } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  // Last path segment, ignoring a trailing slash — same small helper
  // `onboarding-path.ts`'s `basename` provides for the onboarding flow;
  // duplicated here rather than cross-imported from another feature's
  // component dir, matching this codebase's stated preference for
  // colocating small pure helpers per call site (see `mail-shapes.ts`'s
  // `relativeTime` doc comment).
  function basename(path: string): string {
    const trimmed = path.replace(/\/+$/, '');
    const idx = trimmed.lastIndexOf('/');
    return idx === -1 ? trimmed : trimmed.slice(idx + 1);
  }

  let path = $state('');
  let name = $state('');
  let nameEdited = $state(false);
  let submitting = $state(false);
  let error = $state<string | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  $effect(() => {
    if (open) {
      path = '';
      name = '';
      nameEdited = false;
      submitting = false;
      error = null;
    }
  });

  function applyPath(picked: string) {
    path = picked;
    // Only overwrite the name while the user hasn't typed their own —
    // re-picking a folder after editing the name shouldn't clobber it.
    if (!nameEdited) name = basename(picked);
  }

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') applyPath(selected);
  }

  function onNameInput() {
    nameEdited = true;
  }

  function onPathInput() {
    // Dev-mode text input: keep the name in sync with the typed path until
    // the user overrides it, same rule `applyPath` enforces for the Tauri
    // picker.
    if (!nameEdited) name = basename(path);
  }

  async function submit() {
    error = null;

    if (!path.trim()) {
      error = 'Choose a folder to mount.';
      return;
    }
    if (!name.trim()) {
      error = 'Give this mount a name.';
      return;
    }

    submitting = true;
    const result = await mountsStore.declare(name.trim(), path.trim(), workspaceStore.generation ?? 0);
    submitting = false;

    if (!result.ok) {
      error = declareMountErrorMessage(result.error);
      return;
    }

    open = false;
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Mount a folder from elsewhere</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Reads a knowledge folder right where it already lives — nothing is copied or moved.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="mount-elsewhere-path">Folder</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input id="mount-elsewhere-path" bind:value={path} disabled={submitting} readonly placeholder="Choose a folder…" />
            <Button type="button" variant="outline" onclick={pickFolder} disabled={submitting}>Browse…</Button>
          </div>
        {:else}
          <Input
            id="mount-elsewhere-path"
            bind:value={path}
            oninput={onPathInput}
            disabled={submitting}
            placeholder="/Users/you/Documents/client-notes"
          />
          <p class="text-ink-meta text-[11px]">Dev only — the desktop app uses a folder picker here.</p>
        {/if}
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="mount-elsewhere-name">Name</Label>
        <Input id="mount-elsewhere-name" bind:value={name} oninput={onNameInput} disabled={submitting} />
      </div>

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button type="button" onclick={submit} disabled={submitting}>
        {submitting ? 'Mounting…' : 'Mount folder'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
