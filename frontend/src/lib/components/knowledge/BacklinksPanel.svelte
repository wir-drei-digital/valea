<script lang="ts">
  // "Referenced by" panel for a page's editor route (Task C10) — shows every
  // page that links to THIS page, so a reader can see what depends on it
  // before editing or deleting it. Fetches `icmEntryReferences` on every
  // `path` change; renders nothing at all when there are no references
  // (`groupReferences(...).empty`), so a page nobody links to shows no
  // empty panel.
  import { api } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import SectionOverline from '$lib/components/shell/SectionOverline.svelte';
  import { groupReferences, type PageRef } from './backlinks-panel';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  let pages = $state<PageRef[]>([]);

  $effect(() => {
    const requested = path;
    pages = [];

    void api.icmEntryReferences(mountKey, requested).then((result) => {
      // Stale — a newer nav has since taken over; drop a slow response
      // rather than showing backlinks for a page the reader has left.
      if (!result.ok || requested !== path) return;

      const data = result.data as { pages?: PageRef[] };
      const grouped = groupReferences(data);
      pages = grouped.pages;
    });
  });

  const empty = $derived(pages.length === 0);
</script>

{#if !empty}
  <div data-testid="backlinks-panel">
    <SectionOverline label="Referenced by" />
    <ul class="flex flex-col gap-1.5 px-2 pb-2">
      {#each pages as ref (ref.sourcePath)}
        <li class="text-[13px]">
          <a
            href={`/knowledge/${encodeURIComponent(ref.mount)}/${encodePath(ref.sourcePath)}`}
            class="text-ink-body hover:text-ink-heading hover:underline"
          >
            {ref.linkText || ref.sourcePath}
          </a>
        </li>
      {/each}
    </ul>
  </div>
{/if}
