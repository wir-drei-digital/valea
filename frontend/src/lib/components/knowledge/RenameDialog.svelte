<script lang="ts">
  // Rename dialog for a page or folder. Pages get a reference-impact check
  // before the confirm button is usable (`icmEntryReferences` is a per-page
  // lookup — see the backend note in DeleteDialog); folders skip that fetch
  // entirely and show a fixed caution line instead, since the backend's
  // reference search isn't a real folder-scoped query (it's a substring
  // match against workflow YAML, which folder paths would abuse via prefix
  // collisions rather than answer correctly).
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { withBeforeMutate } from './before-mutate';

  let {
    path,
    currentName,
    isFolder,
    open = $bindable(false),
    onBeforeMutate
  }: {
    path: string;
    currentName: string;
    isFolder: boolean;
    open?: boolean;
    /**
     * Awaited before the rename API call fires. Passed by the route when
     * this dialog targets the currently open page, as `() =>
     * store.flush()` — flushes a pending debounced edit to the OLD path
     * first so it isn't lost. Undefined for rows that aren't the open page.
     */
    onBeforeMutate?: () => Promise<void>;
  } = $props();

  let name = $state('');
  let submitting = $state(false);
  let error = $state<string | null>(null);
  let loadingRefs = $state(false);
  let referenceCount = $state<number | null>(null);
  let inputRef = $state<HTMLInputElement | null>(null);

  $effect(() => {
    if (open) {
      name = currentName;
      error = null;
      submitting = false;
      referenceCount = null;

      if (isFolder) {
        loadingRefs = false;
      } else {
        loadingRefs = true;
        void api.icmEntryReferences(path).then((result) => {
          loadingRefs = false;
          if (result.ok) {
            const data = result.data as { workflows: { file: string; name: string }[] };
            referenceCount = data.workflows.length;
          }
        });
      }
    }
  });

  function impactLine(count: number): string {
    return count === 1
      ? 'Also updates 1 workflow that reads this page.'
      : `Also updates ${count} workflows that read this page.`;
  }

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

  // If the renamed entry is (or contains) the page currently open in the
  // main pane, follow it to the new URL rather than leaving the reader on a
  // now-dead path — the watcher will refresh the tree, but it can't fix up
  // the address bar.
  function navigateIfOpen(newPath: string): void {
    const oldEncoded = `/knowledge/${encodePath(path)}`;
    const current = page.url.pathname;

    if (current === oldEncoded) {
      void goto(`/knowledge/${encodePath(newPath)}`);
    } else if (isFolder && current.startsWith(`${oldEncoded}/`)) {
      const suffix = current.slice(oldEncoded.length);
      void goto(`/knowledge/${encodePath(newPath)}${suffix}`);
    }
  }

  async function submit() {
    if (submitting || (!isFolder && loadingRefs)) return;

    const trimmed = name.trim();
    if (!trimmed) {
      error = "That name won't work as a file name. Avoid slashes and leading dots.";
      return;
    }

    error = null;
    submitting = true;
    try {
      const result = await withBeforeMutate(onBeforeMutate, () => api.renameIcmEntry(path, trimmed));

      if (!result.ok) {
        error = mapError(result.error);
        return;
      }

      const newPath = (result.data as { path: string; updatedWorkflows: string[] }).path;
      open = false;
      navigateIfOpen(newPath);
    } catch (err) {
      error = "Couldn't save your latest changes. Fix that first, then try again.";
    } finally {
      submitting = false;
    }
  }

  function onKeydown(event: KeyboardEvent) {
    if (event.key === 'Enter') {
      event.preventDefault();
      void submit();
    }
  }

  const confirmDisabled = $derived(submitting || !name.trim() || (!isFolder && loadingRefs));
</script>

<Dialog.Root bind:open>
  <Dialog.Content
    class="sm:max-w-sm"
    onOpenAutoFocus={(event) => {
      event.preventDefault();
      inputRef?.focus();
      inputRef?.select();
    }}
  >
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Rename "{currentName}"</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        <span class="font-mono text-[12px]">icm/{path}</span>
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-4">
      <div class="flex flex-col gap-1.5">
        <Label for="rename-entry-name">Name</Label>
        <Input
          id="rename-entry-name"
          bind:ref={inputRef}
          bind:value={name}
          disabled={submitting}
          onkeydown={onKeydown}
        />
      </div>

      {#if isFolder}
        <p class="text-suggest-ink text-[12.5px]">Workflow references to pages inside will be updated.</p>
      {:else if loadingRefs}
        <p class="text-ink-meta text-[12.5px]">Checking workflow references…</p>
      {:else if referenceCount}
        <p class="text-suggest-ink text-[12.5px]">{impactLine(referenceCount)}</p>
      {/if}

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button type="button" onclick={submit} disabled={confirmDisabled}>
        {submitting ? 'Renaming…' : 'Rename'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
