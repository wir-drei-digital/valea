<script lang="ts">
  import { AppFrame, ListPane } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { encodePath } from '$lib/shell/nav';
  import { Button } from '$lib/components/ui/button/index.js';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
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
    <ListPane>
      {#snippet header()}
        <p class="text-overline">Knowledge</p>
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#each folders as folder (folder.path)}
            <li class="group relative">
              <a
                href={`/knowledge/${encodePath(folder.path)}`}
                class="flex items-center gap-2 py-2 pr-9 pl-3 text-[13px] text-ink-body transition-colors hover:bg-paper-pill"
              >
                <span class="min-w-0 flex-1 truncate">{folder.name}</span>
                <span class="text-ink-meta text-[11px] tabular-nums">{folder.pageCount ?? 0}</span>
              </a>
              <EntryMenu
                path={folder.path}
                name={folder.name}
                isFolder={true}
                class="absolute top-1/2 right-1.5 -translate-y-1/2"
              />
            </li>
          {/each}
        </ul>
      {/snippet}
      {#snippet footer()}
        <div class="flex gap-2">
          <Button type="button" variant="outline" size="sm" class="flex-1" onclick={() => openNew('page')}>
            New page
          </Button>
          <Button type="button" variant="outline" size="sm" class="flex-1" onclick={() => openNew('folder')}>
            New folder
          </Button>
        </div>
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

<NewEntryDialog mode={newEntryMode} parentPath="" bind:open={newEntryOpen} />
