<script lang="ts">
  // The chat session's header line (extracted from the chat route,
  // side-panes pass): which ICM the session works in, an archive affordance
  // when ended, and — when the host can open files — the folder name becomes
  // a popover file tree for opening a file beside the chat.
  //
  // Presentational: every piece of state (which ICM, whether the session
  // ended, whether an archive call is in flight) arrives as a prop, so the
  // same header renders for a route primary and for a session inside a side
  // pane. The popover half only exists when the host actually passes
  // `onOpenFile` — a host with nowhere to put a file renders the plain
  // static folder line the route always had.
  import Folder from '@lucide/svelte/icons/folder';
  import Archive from '@lucide/svelte/icons/archive';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import * as Popover from '$lib/components/ui/popover';
  import { IcmTree } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { icmToNav } from '$lib/shell/nav';

  let {
    icmName,
    mountKey,
    ended,
    archiving,
    onArchive,
    onOpenFile
  }: {
    icmName: string | null;
    mountKey: string | null;
    ended: boolean;
    archiving: boolean;
    onArchive?: () => void;
    onOpenFile?: (sel: { mountKey: string; path: string }) => void;
  } = $props();

  let treeOpen = $state(false);
  // `icmStore.groups` is keyed by `mount` (the stable mount key) — the same
  // key sessions carry as `icmMount`. Folders inside the popover lazy-load
  // through `IcmTree`'s own `loadDir` calls; the mount's ROOT level is the
  // caller's concern (see `ChatView`'s tree-load effect).
  const treeNav = $derived(icmToNav(icmStore.groups.find((g) => g.mount === mountKey)?.tree ?? []));
  const canBrowse = $derived(Boolean(onOpenFile && mountKey));
</script>

{#if icmName || ended}
  <div class="border-paper-hairline flex items-center gap-1.5 border-b px-4 pb-2">
    {#if icmName}
      {#if canBrowse}
        <Popover.Root bind:open={treeOpen}>
          <Popover.Trigger
            class="hover:bg-paper-pill -mx-1 flex items-center gap-1.5 rounded-md px-1 py-0.5 transition-colors"
          >
            <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
            <span class="text-ink-meta text-[12px]">
              Working in <span class="text-ink-secondary font-medium">{icmName}</span>
            </span>
            <ChevronDown class="text-ink-meta size-3 shrink-0" strokeWidth={1.5} aria-hidden="true" />
          </Popover.Trigger>
          <Popover.Content class="max-h-96 overflow-y-auto p-2">
            {#if treeNav.length}
              <IcmTree
                nodes={treeNav}
                onSelect={(sel) => {
                  treeOpen = false;
                  onOpenFile?.(sel);
                }}
              />
            {:else}
              <p class="text-ink-meta px-2 py-1 text-[12px]">No files yet.</p>
            {/if}
          </Popover.Content>
        </Popover.Root>
      {:else}
        <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
        <span class="text-ink-meta text-[12px]">
          Working in <span class="text-ink-secondary font-medium">{icmName}</span>
        </span>
      {/if}
    {/if}
    <span class="min-w-0 flex-1" aria-hidden="true"></span>
    {#if ended && onArchive}
      <button
        type="button"
        onclick={onArchive}
        disabled={archiving}
        class="text-ink-meta hover:text-ink-heading flex shrink-0 items-center gap-1 text-[12px] transition-colors"
      >
        <Archive class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
        {archiving ? 'Archiving…' : 'Archive'}
      </button>
    {/if}
  </div>
{/if}
