<script lang="ts">
  import { AppFrame, ListPane } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { encodePath } from '$lib/shell/nav';

  const folders = $derived(icmStore.nodes.filter((n) => n.type === 'folder'));
</script>

<AppFrame>
  {#snippet list()}
    <ListPane>
      {#snippet header()}
        <p class="text-overline">Knowledge</p>
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#each folders as folder (folder.path)}
            <li>
              <a
                href={`/knowledge/${encodePath(folder.path)}`}
                class="flex items-center gap-2 px-3 py-2 text-[13px] text-ink-body transition-colors hover:bg-paper-pill"
              >
                <span class="min-w-0 flex-1 truncate">{folder.name}</span>
                <span class="text-ink-meta text-[11px] tabular-nums">{folder.pageCount ?? 0}</span>
              </a>
            </li>
          {/each}
        </ul>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    <header class="flex flex-col gap-2">
      <h1 class="font-display text-[24px] text-ink-heading">Knowledge</h1>
      <p class="max-w-[520px] text-[13.5px] text-ink-body">
        Your business memory — every page is a plain Markdown file in your workspace.
      </p>
    </header>
  {/snippet}
</AppFrame>
