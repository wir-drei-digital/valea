<script lang="ts">
  import type { NavTreeItem } from '$lib/shell/nav';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import IcmTree from './IcmTree.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';

  let { nodes, activePath = '' }: { nodes: NavTreeItem[]; activePath?: string } = $props();

  // Folders default open so the tree "mirrors icm/ exactly" (§7) without extra clicks.
  let open = $state<Record<string, boolean>>({});

  function isOpen(item: NavTreeItem) {
    return open[item.href] ?? true;
  }

  function toggle(item: NavTreeItem) {
    open[item.href] = !isOpen(item);
  }

  // Ancestor folders (current path nested under this folder) get the lighter
  // nav-active treatment; only the exact page/folder match gets the deeper
  // tree-active fill (§7: "Tree active row uses the deeper #EEE5CF").
  function isAncestor(item: NavTreeItem) {
    return activePath.startsWith(item.href + '/');
  }
</script>

<ul class="flex flex-col gap-0.5">
  {#each nodes as node (node.href)}
    <li>
      {#if node.children}
        <div class="group relative">
          <button
            type="button"
            onclick={() => toggle(node)}
            aria-current={activePath === node.href ? 'page' : undefined}
            class={[
              'flex w-full items-center gap-1 rounded-md py-[3px] pr-8 pl-2 text-left text-[12.5px] transition-colors hover:bg-paper-pill',
              activePath === node.href
                ? 'bg-paper-tree-active text-ink-heading'
                : isAncestor(node)
                  ? 'bg-paper-nav-active text-ink-heading'
                  : 'text-ink-secondary'
            ]}
          >
            <ChevronRight
              class={['size-3 shrink-0 text-ink-meta transition-transform', isOpen(node) ? 'rotate-90' : '']}
              strokeWidth={1.5}
            />
            <span class="flex-1 truncate">{node.label}</span>
            {#if node.count !== undefined}
              <span class="text-ink-meta text-[11px] tabular-nums">{node.count}</span>
            {/if}
          </button>
          <EntryMenu
            path={node.path}
            name={node.label}
            isFolder={true}
            class="absolute top-1/2 right-0.5 -translate-y-1/2"
          />
        </div>
        {#if isOpen(node) && node.children.length}
          <div class="ml-[17px] border-l border-paper-chip-border pl-2">
            <IcmTree nodes={node.children} {activePath} />
          </div>
        {/if}
      {:else}
        <div class="group relative">
          <a
            href={node.href}
            aria-current={activePath === node.href ? 'page' : undefined}
            class={[
              'flex items-center gap-1 rounded-md py-[3px] pr-8 pl-2 text-[12.5px] transition-colors hover:bg-paper-pill',
              activePath === node.href ? 'bg-paper-tree-active text-ink-heading' : 'text-ink-secondary'
            ]}
          >
            <span class="flex-1 truncate">{node.label}</span>
          </a>
          <EntryMenu
            path={node.path}
            name={node.label}
            isFolder={false}
            class="absolute top-1/2 right-0.5 -translate-y-1/2"
          />
        </div>
      {/if}
    </li>
  {/each}
</ul>
