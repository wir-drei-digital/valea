<script lang="ts">
  // Guided fallback for "Start the conversation" until the chat-based setup
  // assistant exists (Phase 6+). Card copy ships as designed; only the
  // behavior behind the button is this dialog.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let { open = $bindable(false) }: { open?: boolean } = $props();

  let name = $state('My business');
  let parentDir = $state('');
  let submitting = $state(false);
  let error = $state<string | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      parentDir = selected;
    }
  }

  function mapErrorCode(code: string): string {
    switch (code) {
      case 'target_not_empty':
        return 'That folder already has files in it. Pick an empty spot for a new workspace.';
      case 'not_a_workspace':
        return "This folder doesn't look like a Valea workspace.";
      default:
        return 'Something went wrong while creating the workspace. Try again.';
    }
  }

  async function submit() {
    error = null;
    if (!parentDir.trim()) {
      error = 'Choose a folder to create the workspace in.';
      return;
    }
    if (!name.trim()) {
      error = 'Give the workspace a name.';
      return;
    }

    submitting = true;
    const result = await workspaceStore.create(parentDir.trim(), name.trim());
    submitting = false;

    if (!result.ok) {
      error = mapErrorCode(result.error);
      return;
    }

    open = false;
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Set up your workspace</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Choose a name and a folder. The app scaffolds a workspace there and opens it — nothing connects without
        asking you.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="workspace-name">Workspace name</Label>
        <Input id="workspace-name" bind:value={name} disabled={submitting} placeholder="My business" />
      </div>

      <div class="flex flex-col gap-1.5">
        <Label for="workspace-parent-dir">Parent folder</Label>
        {#if isTauri}
          <div class="flex gap-2">
            <Input
              id="workspace-parent-dir"
              bind:value={parentDir}
              disabled={submitting}
              readonly
              placeholder="Choose a folder…"
            />
            <Button type="button" variant="outline" onclick={pickFolder} disabled={submitting}>Browse…</Button>
          </div>
        {:else}
          <Input
            id="workspace-parent-dir"
            bind:value={parentDir}
            disabled={submitting}
            placeholder="/Users/you/Documents"
          />
        {/if}
      </div>

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button type="button" onclick={submit} disabled={submitting}>
        {submitting ? 'Setting up…' : 'Create workspace'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
