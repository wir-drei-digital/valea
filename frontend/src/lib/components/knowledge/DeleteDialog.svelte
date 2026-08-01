<script lang="ts">
  // Delete confirmation for a page, a non-.md file, or a folder. Leaf rows
  // of either kind fetch their reference list on open so the warning can
  // name the pages that would break (Task C10 — and an embedded image or
  // PDF resolves through the same AST-confirmed lookup a page does);
  // folders skip the fetch (see RenameDialog's note — the backend's
  // reference search resolves a single exact target path, not a real
  // folder-scoped query) and show a fixed caution line instead.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { followMutation } from './follow-mutation';
  import { withBeforeMutate } from './before-mutate';
  import { groupReferences, deleteImpactLine, type PageRef } from './backlinks-panel';
  import { referenceNoun, type EntryKind } from './entry-kind';

  let {
    mountKey,
    path,
    name,
    kind,
    open = $bindable(false),
    onBeforeMutate,
    onDeleted
  }: {
    mountKey: string;
    path: string;
    name: string;
    kind: EntryKind;
    open?: boolean;
    /**
     * Awaited before the delete API call fires. Passed by the route when
     * this dialog targets the currently open page, as `() =>
     * store.flush()` — flushes a pending debounced edit to disk first so a
     * concurrently-deleted page doesn't erase an unsaved change. Undefined
     * for rows that aren't the open page.
     */
    onBeforeMutate?: () => Promise<void>;
    /**
     * Fired once the entry is gone and BEFORE `followMutation` navigates, for
     * a caller holding state indexed into a list of open files. `followMutation`
     * removes the deleted path from every surface's list straight in the URL,
     * which renumbers those lists without any of the usual close paths running
     * — so an index-shaped claim (the Files pane's auto-open claim) would
     * silently start naming a different file. Before the navigation, because
     * the holder reads its pre-removal indexes to do the re-mapping.
     */
    onDeleted?: () => void;
  } = $props();

  let submitting = $state(false);
  let error = $state<string | null>(null);
  let loadingRefs = $state(false);
  let referencedPages = $state<PageRef[]>([]);

  // Only the folder/not-folder split gates behavior here (the reference
  // fetch, and whether an open descendant counts as "this page is gone");
  // `kind` beyond that just picks the noun in the impact line.
  const isFolder = $derived(kind === 'folder');
  const impact = $derived(deleteImpactLine(referencedPages.length, referenceNoun(kind)));

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

      // Deleting the entry a reader currently has open (or, for a folder, any
      // page nested under it) leaves a surface pointing at nothing.
      //
      // `followMutation` asks that question of EVERY surface, not just the
      // route's pathname: the primary's other tabs (`?tabs=`) and any Files
      // pane (`?pane=files:…`) can be showing it too, and neither is visible
      // to a pathname comparison. Per the spec's per-subject rule it drops the
      // one file and keeps the rest — sibling tabs survive, and a Files pane
      // left with nothing stays open as its tree rather than closing and
      // taking the navigator with it. `?pane=` rides along on the primary's
      // fallback exactly as the route's own `onVanished` does; the two paths
      // must not disagree about whether an open session survives.
      // Before the navigation: the listener re-maps indexes it reads off the
      // list `followMutation` is about to renumber.
      onDeleted?.();

      const href = followMutation(page.url, { mountKey, path, isFolder }, null);
      if (href) void goto(href);
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
