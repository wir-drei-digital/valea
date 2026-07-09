<script lang="ts">
  import type { NavTreeItem } from '$lib/shell/nav';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import IcmTree from './IcmTree.svelte';

  let { nodes, activePath = '' }: { nodes: NavTreeItem[]; activePath?: string } = $props();

  // Folders default open so the tree "mirrors icm/ exactly" (§7) without extra clicks.
  let open = $state<Record<string, boolean>>({});

  function isOpen(item: NavTreeItem) {
    return open[item.href] ?? true;
  }

  function toggle(item: NavTreeItem) {
    open[item.href] = !isOpen(item);
  }
</script>

<ul class="flex flex-col gap-0.5">
  {#each nodes as node (node.href)}
    <li>
      {#if node.children}
        <button
          type="button"
          onclick={() => toggle(node)}
          class={[
            'flex w-full items-center gap-1 rounded-md px-2 py-[3px] text-left text-[12.5px] transition-colors hover:bg-paper-pill',
            activePath === node.href ? 'bg-paper-nav-active text-ink-heading' : 'text-ink-secondary'
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
        {#if isOpen(node) && node.children.length}
          <div class="ml-[17px] border-l border-paper-chip-border pl-2">
            <IcmTree nodes={node.children} {activePath} />
          </div>
        {/if}
      {:else}
        <a
          href={node.href}
          class={[
            'flex items-center gap-1 rounded-md px-2 py-[3px] text-[12.5px] transition-colors hover:bg-paper-pill',
            activePath === node.href ? 'bg-paper-nav-active text-ink-heading' : 'text-ink-secondary'
          ]}
        >
          <span class="flex-1 truncate">{node.label}</span>
        </a>
      {/if}
    </li>
  {/each}
</ul>
