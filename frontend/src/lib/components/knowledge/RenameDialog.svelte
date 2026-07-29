<script lang="ts">
  // Rename dialog for a page, a non-.md file, or a folder. Leaf rows of
  // either kind get a reference-impact check before the confirm button is
  // usable (`icmEntryReferences` is a per-target lookup — see the backend
  // note in DeleteDialog — and it resolves an embedded image or PDF exactly
  // like a page: `Valea.ICM.Backlinks` confirms Link/Image AST
  // destinations, which were never `.md`-only); folders skip that fetch
  // entirely and show a fixed caution line instead, since the backend's
  // reference search resolves a single exact target path, not a real
  // folder-scoped query.
  //
  // `currentName` is the row's own label, so a file leaf pre-fills its FULL
  // basename (`brochure.pdf`) while a page pre-fills its title without the
  // extension — matching what the backend does with the submitted name
  // (`Valea.ICM.rename_target_name/3`: `.md` ensured for a page, taken as
  // typed for anything else).
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { api } from '$lib/api/client';
  import { knowledgeHref } from '$lib/shell/nav';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { hrefWithPane } from '$lib/panes/pane-route';
  import { withBeforeMutate } from './before-mutate';
  import { groupReferences, impactLine, type PageRef } from './backlinks-panel';
  import { referenceNoun, type EntryKind } from './entry-kind';

  let {
    mountKey,
    path,
    currentName,
    kind,
    open = $bindable(false),
    onBeforeMutate
  }: {
    mountKey: string;
    path: string;
    currentName: string;
    kind: EntryKind;
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
  let referencePages = $state<PageRef[]>([]);
  let inputRef = $state<HTMLInputElement | null>(null);

  // Only the folder/not-folder split gates behavior here (the reference
  // fetch); `kind` beyond that just picks the noun in the impact line.
  const isFolder = $derived(kind === 'folder');
  const impact = $derived(impactLine(referencePages.length, referenceNoun(kind)));

  $effect(() => {
    if (open) {
      name = currentName;
      error = null;
      submitting = false;
      referencePages = [];

      if (isFolder) {
        loadingRefs = false;
      } else {
        loadingRefs = true;
        void api.icmEntryReferences(mountKey, path).then((result) => {
          loadingRefs = false;
          if (result.ok) {
            const data = result.data as { pages?: PageRef[] };
            const grouped = groupReferences(data);
            referencePages = grouped.pages;
          }
        });
      }
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

  // If the renamed entry is (or contains) the page currently open in the
  // main pane, follow it to the new URL rather than leaving the reader on a
  // now-dead path — the watcher will refresh the tree, but it can't fix up
  // the address bar. Side-panes pass: following the page moves the PRIMARY,
  // so `?pane=` rides along (`hrefWithPane`) — renaming the page you're
  // reading must not close the session open beside it.
  function navigateIfOpen(newPath: string): void {
    const oldEncoded = knowledgeHref(mountKey, path);
    const current = page.url.pathname;

    if (current === oldEncoded) {
      void goto(hrefWithPane(knowledgeHref(mountKey, newPath), page.url));
    } else if (isFolder && current.startsWith(`${oldEncoded}/`)) {
      // `suffix` is sliced off the live pathname, so it is already encoded.
      const suffix = current.slice(oldEncoded.length);
      void goto(hrefWithPane(`${knowledgeHref(mountKey, newPath)}${suffix}`, page.url));
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
      const result = await withBeforeMutate(onBeforeMutate, () => api.renameIcmEntry(mountKey, path, trimmed));

      if (!result.ok) {
        error = mapError(result.error);
        return;
      }

      const newPath = (result.data as { path: string; updatedPages: string[] }).path;
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
        <p class="text-suggest-ink text-[12.5px]">References to pages inside will be updated.</p>
      {:else if loadingRefs}
        <p class="text-ink-meta text-[12.5px]">Checking references…</p>
      {:else if impact}
        <p class="text-suggest-ink text-[12.5px]">{impact}</p>
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
