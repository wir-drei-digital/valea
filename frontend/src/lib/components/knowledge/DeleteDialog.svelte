<script lang="ts">
  // Delete confirmation for a page or folder. Pages fetch their reference
  // list on open so the warning can name the pages that would break (Task
  // C10); folders skip the fetch (see RenameDialog's note — the backend's
  // reference search resolves a single exact target path, not a real
  // folder-scoped query) and show a fixed caution line instead.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { withBeforeMutate } from './before-mutate';
  import { groupReferences, deleteImpactLine, type PageRef } from './backlinks-panel';

  let {
    mountKey,
    path,
    name,
    isFolder,
    open = $bindable(false),
    onBeforeMutate
  }: {
    mountKey: string;
    path: string;
    name: string;
    isFolder: boolean;
    open?: boolean;
    /**
     * Awaited before the delete API call fires. Passed by the route when
     * this dialog targets the currently open page, as `() =>
     * store.flush()` — flushes a pending debounced edit to disk first so a
     * concurrently-deleted page doesn't erase an unsaved change. Undefined
     * for rows that aren't the open page.
     */
    onBeforeMutate?: () => Promise<void>;
  } = $props();

  let submitting = $state(false);
  let error = $state<string | null>(null);
  let loadingRefs = $state(false);
  let referencedPages = $state<PageRef[]>([]);

  const impact = $derived(deleteImpactLine(referencedPages.length));

  $effect(() => {
    if (open) {
      error = null;
      submitting = false;
      referencedPages = [];

      if (isFolder) {
        loadingRefs = false;
      } else {
        loadingRefs = true;
        void api.icmEntryReferences(mountKey, path).then((result) => {
          loadingRefs = false;
          if (result.ok) {
            const data = result.data as { pages?: PageRef[] };
            const grouped = groupReferences(data);
            referencedPages = grouped.pages;
          }
        });
      }
    }
  });

  function mapError(code: string): string {
    switch (code) {
      case 'not_found':
        return 'That file is already gone.';
      default:
        return 'Something went wrong. Try again.';
    }
  }

  async function submit() {
    if (submitting || loadingRefs) return;

    error = null;
    submitting = true;
    try {
      const result = await withBeforeMutate(onBeforeMutate, () => api.deleteIcmEntry(mountKey, path));

      if (!result.ok) {
        error = mapError(result.error);
        return;
      }

      open = false;

      // Deleting the entry the reader currently has open (or, for a folder,
      // any page nested under it) leaves the URL pointing at nothing — send
      // them back to the Knowledge root rather than showing a dead page.
      const encoded = `/knowledge/${encodeURIComponent(mountKey)}/${encodePath(path)}`;
      const current = page.url.pathname;
      if (current === encoded || (isFolder && current.startsWith(`${encoded}/`))) {
        void goto('/knowledge');
      }
    } catch (err) {
      error = "Couldn't save your latest changes. Fix that first, then try again.";
    } finally {
      submitting = false;
    }
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-sm">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Delete "{name}"</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        <span class="font-mono text-[12px]">icm/{path}</span>
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-3">
      {#if isFolder}
        <p class="text-warn-ink text-[12.5px]">Pages may reference entries inside this folder.</p>
      {:else if loadingRefs}
        <p class="text-ink-meta text-[12.5px]">Checking references…</p>
      {:else if impact}
        <p class="text-warn-ink text-[12.5px]">{impact}</p>
        <ul class="flex flex-col gap-1">
          {#each referencedPages as ref (ref.sourcePath)}
            <li class="text-warn-ink text-[12.5px]">{ref.linkText || ref.sourcePath} links here. That link will break.</li>
          {/each}
        </ul>
      {/if}

      <p class="text-ink-body text-[13.5px]">
        {isFolder
          ? 'This removes the folder and everything in it from your workspace folder.'
          : 'This removes the file from your workspace folder.'}
      </p>

      {#if error}
        <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button
        type="button"
        variant="outline"
        class="border-warn-border text-warn-ink hover:bg-warn-tint hover:text-warn-ink"
        onclick={submit}
        disabled={submitting || loadingRefs}
      >
        {submitting ? 'Deleting…' : 'Delete'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
