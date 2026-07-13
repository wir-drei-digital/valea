<script lang="ts">
  // "Referenced by" panel for a page's editor route (Task C10) — shows every
  // page and workflow that links to/reads THIS page, so a reader can see
  // what depends on it before editing or deleting it. Fetches
  // `icmEntryReferences` on every `path` change; renders nothing at all
  // when there are no references (`groupReferences(...).empty`), so a page
  // nobody links to shows no empty panel.
  import { api } from '$lib/api/client';
  import { encodePath } from '$lib/shell/nav';
  import SectionOverline from '$lib/components/shell/SectionOverline.svelte';
  import { groupReferences, type PageRef, type WorkflowRef } from './backlinks-panel';

  let { path }: { path: string } = $props();

  let pages = $state<PageRef[]>([]);
  let workflows = $state<WorkflowRef[]>([]);

  $effect(() => {
    const requested = path;
    pages = [];
    workflows = [];

    void api.icmEntryReferences(requested).then((result) => {
      // Stale — a newer nav has since taken over; drop a slow response
      // rather than showing backlinks for a page the reader has left.
      if (!result.ok || requested !== path) return;

      const data = result.data as { workflows?: WorkflowRef[]; pages?: PageRef[] };
      const grouped = groupReferences(data);
      pages = grouped.pages;
      workflows = grouped.workflows;
    });
  });

  const empty = $derived(pages.length === 0 && workflows.length === 0);
</script>

{#if !empty}
  <div data-testid="backlinks-panel">
    <SectionOverline label="Referenced by" />
    <ul class="flex flex-col gap-1.5 px-2 pb-2">
      {#each pages as ref (ref.sourcePath)}
        <li class="text-[13px]">
          <a
            href={`/knowledge/${encodePath(ref.sourcePath)}`}
            class="text-ink-body hover:text-ink-heading hover:underline"
          >
            {ref.linkText || ref.sourcePath}
          </a>
        </li>
      {/each}
      {#each workflows as workflow (workflow.file)}
        <li class="text-ink-body text-[13px]">
          {workflow.name}
          <span class="text-ink-meta text-[11px]"> · workflow</span>
        </li>
      {/each}
    </ul>
  </div>
{/if}
