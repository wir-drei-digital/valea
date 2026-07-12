<script lang="ts">
  import { AppFrame, ListPane, PageHeader } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { encodePath } from '$lib/shell/nav';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';

  const folders = $derived(icmStore.nodes.filter((n) => n.type === 'folder'));

  let newEntryMode: 'page' | 'folder' = $state('page');
  let newEntryOpen = $state(false);

  function openNew(mode: 'page' | 'folder') {
    newEntryMode = mode;
    newEntryOpen = true;
  }
</script>

<AppFrame>
  {#snippet list()}
    <ListPane title="Knowledge">
      {#snippet action()}
        <NewEntryButton onNew={openNew} />
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#each folders as folder (folder.path)}
            <li class="group relative">
              <a
                href={`/knowledge/${encodePath(folder.path)}`}
                class="text-ink-body hover:bg-paper-pill flex items-center gap-2 border-l-[3px] border-transparent py-2 pr-9 pl-3 text-[13px] transition-colors"
              >
                <span class="min-w-0 flex-1 truncate">{folder.name}</span>
                <span class="text-ink-meta text-[11px] tabular-nums">{folder.pageCount ?? 0}</span>
              </a>
              <EntryMenu
                path={folder.path}
                name={folder.name}
                isFolder={true}
                class="absolute top-1/2 right-0.5 -translate-y-1/2"
              />
            </li>
          {/each}
        </ul>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    <PageHeader
      title="Knowledge"
      subtitle="Your business memory — every page is a plain Markdown file in your workspace."
    />
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} parentPath="" bind:open={newEntryOpen} />
