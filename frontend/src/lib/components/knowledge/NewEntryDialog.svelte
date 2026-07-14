<script lang="ts">
  // Create-page / create-folder dialog, shared by both modes so the error
  // mapping and layout stay in one place. Pages land the user straight in
  // the editor on success; folders just close — the watcher (icm_changed)
  // refreshes the tree, so there's nothing to navigate to yet.
  //
  // Page mode also offers a "Start from" template select (Task C10) —
  // options come from `templateOptions`, which only ever offers templates
  // from the mount that owns `parentPath` (`createIcmPageFromTemplate`
  // requires template and new page to share a mount). Leaving it on the
  // default "Empty page" (`templatePath === ''`) keeps the pre-C10
  // `createIcmPage` call path exactly as it was.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import { goto } from '$app/navigation';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { templateOptions } from './template-options';

  let {
    mode,
    mountKey,
    parentPath,
    open = $bindable(false)
  }: { mode: 'page' | 'folder'; mountKey: string; parentPath: string; open?: boolean } = $props();

  let name = $state('');
  let submitting = $state(false);
  let error = $state<string | null>(null);
  let inputRef = $state<HTMLInputElement | null>(null);
  // "Start from" (Task C10) — the chosen template's path, or '' for "Empty
  // page" (the pre-C10 default create-a-blank-page behavior). Folder mode
  // never reads this.
  let templatePath = $state('');

  const options = $derived(mode === 'page' ? templateOptions(icmStore.groups, mountKey) : []);

  // Reset to a clean slate every time the dialog opens — it's a shared
  // instance reused across many create actions, not remounted per open.
  $effect(() => {
    if (open) {
      name = '';
      error = null;
      submitting = false;
      templatePath = '';
    }
  });

  function mapError(code: string): string {
    switch (code) {
      case 'name_invalid':
        return "That name won't work as a file name. Avoid slashes and leading dots.";
      case 'already_exists':
        return 'Something with that name is already there.';
      default:
        return 'Something went wrong. Try again.';
    }
  }

  async function submit() {
    const trimmed = name.trim();
    if (!trimmed) {
      error = "That name won't work as a file name. Avoid slashes and leading dots.";
      return;
    }

    error = null;
    submitting = true;
    const result =
      mode === 'folder'
        ? await api.createIcmFolder(mountKey, parentPath, trimmed)
        : templatePath
          ? await api.createIcmPageFromTemplate(mountKey, parentPath, trimmed, mountKey, templatePath)
          : await api.createIcmPage(mountKey, parentPath, trimmed);
    submitting = false;

    if (!result.ok) {
      error = mapError(result.error);
      return;
    }

    const path = (result.data as { path: string }).path;
    open = false;
    if (mode === 'page') {
      void goto(`/knowledge/${encodeURIComponent(mountKey)}/${encodePath(path)}`);
    }
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      void submit();
    }
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content
    class="sm:max-w-sm"
    onOpenAutoFocus={(event) => {
      event.preventDefault();
      inputRef?.focus();
    }}
  >
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">
        {mode === 'page' ? 'New page' : 'New folder'}
      </Dialog.Title>
      <Dialog.Description class="text-ink-body">
        {mode === 'page' ? 'Adds a Markdown page to' : 'Adds a folder to'}
        <span class="font-mono text-[12px]">{parentPath}</span>
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="new-entry-name">Name</Label>
        <Input
          id="new-entry-name"
          bind:ref={inputRef}
          bind:value={name}
          disabled={submitting}
          placeholder={mode === 'page' ? 'Email Tone Guide' : 'Tone & Voice'}
          onkeydown={onKeydown}
        />
      </div>

      {#if mode === 'page'}
        <div class="flex flex-col gap-1.5">
          <Label for="new-entry-template">Start from</Label>
          <select
            id="new-entry-template"
            bind:value={templatePath}
            disabled={submitting}
            class="border-input focus-visible:border-ring h-8 rounded-lg border bg-transparent px-2.5 py-1 text-[13.5px] text-ink-body outline-none disabled:pointer-events-none disabled:opacity-50"
          >
            <option value="">Empty page</option>
            {#each options as option (option.path)}
              <option value={option.path}>{option.label}</option>
            {/each}
          </select>
        </div>
      {/if}

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button type="button" onclick={submit} disabled={submitting}>
        {submitting ? 'Creating…' : mode === 'page' ? 'Create page' : 'Create folder'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
