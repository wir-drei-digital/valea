<script lang="ts">
  import type { NavTreeItem } from '$lib/shell/nav';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import IcmTree from './IcmTree.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';
  import { fileLeafLabel } from '$lib/components/knowledge/file-leaf';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';

  let {
    nodes,
    activePath = '',
    onBeforeMutate,
    onSelect
  }: {
    nodes: NavTreeItem[];
    activePath?: string;
    /**
     * Flushes the currently open page's pending edit before a rename/delete
     * mutate call fires (see route + before-mutate.ts). Only ever wired to
     * the EntryMenu for the row whose `href` matches `activePath` — every
     * other row passes nothing through.
     */
    onBeforeMutate?: () => Promise<void>;
    /**
     * Selection mode (side-panes pass): when set, leaf rows call this
     * instead of navigating (used by popover pickers); EntryMenu is hidden
     * on every row, since picking a file is not the place to rename or
     * delete one. Folder expand/collapse behaves identically in both modes.
     */
    onSelect?: (sel: { mountKey: string; path: string }) => void;
  } = $props();

  // Folders default CLOSED (file-browser performance pass): the lazy tree
  // only fetches a folder's listing when it's opened. Expansion state lives
  // in the shared, localStorage-persisted `treeOpenState` (keyed by href),
  // so the folders someone works in stay open across routes and reloads.
  function toggle(item: NavTreeItem) {
    treeOpenState.toggle(item.href);
    if (treeOpenState.isOpen(item.href) && item.loaded === false) {
      void icmStore.loadDir(item.mountKey, item.path);
    }
  }

  // Self-healing loader: a row can be open without a click ever having
  // fired `loadDir` for it — persisted expansion restored on a fresh
  // session, or a refetch that dropped a stale loaded-mark (see
  // `IcmStore.refetch`'s reconcile step). Whenever an open folder shows an
  // unloaded placeholder, fetch it; `loadDir` de-dupes, so this is a no-op
  // in the steady state.
  $effect(() => {
    for (const node of nodes) {
      if (node.children && node.loaded === false && treeOpenState.isOpen(node.href)) {
        void icmStore.loadDir(node.mountKey, node.path);
      }
    }
  });
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
            aria-expanded={treeOpenState.isOpen(node.href)}
            class={[
              'flex w-full items-center gap-1 rounded-md py-[3px] pr-9 pl-2 text-left text-[12.5px] transition-colors hover:bg-paper-pill',
              activePath === node.href ? 'bg-paper-tree-active text-ink-heading' : 'text-ink-secondary'
            ]}
          >
            <ChevronRight
              class={[
                'size-3 shrink-0 text-ink-meta transition-transform',
                treeOpenState.isOpen(node.href) ? 'rotate-90' : ''
              ]}
              strokeWidth={1.5}
            />
            <span class="flex-1 truncate">{node.label}</span>
            {#if node.count !== undefined}
              <span class="text-ink-meta text-[11px] tabular-nums">{node.count}</span>
            {/if}
          </button>
          {#if !onSelect}
            <EntryMenu
              mountKey={node.mountKey}
              path={node.path}
              name={node.label}
              isFolder={true}
              class="absolute top-1/2 right-0.5 -translate-y-1/2"
              onBeforeMutate={activePath === node.href ? onBeforeMutate : undefined}
            />
          {/if}
        </div>
        {#if treeOpenState.isOpen(node.href)}
          <div class="ml-[17px] border-l border-paper-chip-border pl-2">
            {#if node.loaded === false}
              <p class="text-ink-meta px-2 py-[3px] text-[12px]">Loading…</p>
            {:else if node.children.length}
              <IcmTree nodes={node.children} {activePath} {onBeforeMutate} {onSelect} />
            {:else}
              <p class="text-ink-meta px-2 py-[3px] text-[12px] italic">Empty</p>
            {/if}
          </div>
        {/if}
      {:else}
        <div class="group relative">
          {#if onSelect}
            <button
              type="button"
              onclick={() => onSelect?.({ mountKey: node.mountKey, path: node.path })}
              class="hover:bg-paper-pill text-ink-secondary flex w-full items-center gap-1 rounded-md py-[3px] pr-2 pl-2 text-left text-[12.5px] transition-colors"
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.ext}
                <!-- Format badge for a non-.md file leaf — the same
                     `fileLeafLabel` text the separate (now removed)
                     non-clickable file rows showed. -->
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">
                  {fileLeafLabel(node.ext)}
                </span>
              {/if}
            </button>
          {:else}
            <a
              href={node.href}
              aria-current={activePath === node.href ? 'page' : undefined}
              class={[
                'flex items-center gap-1 rounded-md py-[3px] pr-9 pl-2 text-[12.5px] transition-colors hover:bg-paper-pill',
                activePath === node.href ? 'bg-paper-tree-active text-ink-heading' : 'text-ink-secondary'
              ]}
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.ext}
                <!-- Format badge for a non-.md file leaf — the same
                     `fileLeafLabel` text the separate (now removed)
                     non-clickable file rows showed. -->
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">
                  {fileLeafLabel(node.ext)}
                </span>
              {/if}
            </a>
            <EntryMenu
              mountKey={node.mountKey}
              path={node.path}
              name={node.label}
              isFolder={false}
              class="absolute top-1/2 right-0.5 -translate-y-1/2"
              onBeforeMutate={activePath === node.href ? onBeforeMutate : undefined}
            />
          {/if}
        </div>
      {/if}
    </li>
  {/each}
</ul>
