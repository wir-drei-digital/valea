<script lang="ts">
  // The chat session's header line (extracted from the chat route,
  // side-panes pass): which ICM the session works in, an archive affordance,
  // and — when the host can open files — the folder name becomes a popover
  // file tree for opening a file beside the chat.
  //
  // Presentational: every piece of state (which ICM, whether the session
  // ended, whether an archive call is in flight) arrives as a prop, so the
  // same header renders for a route primary and for a session inside a side
  // pane. The popover half only exists when the host actually passes
  // `onOpenFile` — a host with nowhere to put a file renders the plain
  // static folder line the route always had.
  //
  // `onArchive` is the "there is a session here" signal (the route's old
  // `selectedId` gate): a host in new-session mode has no session yet and
  // passes none. Both session actions live behind one ellipsis popover:
  // Archive (LIVE sessions archive too — the backend stops a running one
  // first, `Valea.Agents.archive_session/1` — so `ended` only picks the
  // LABEL) and Delete, which is permanent and therefore swaps to an inline
  // confirm row before `onDelete` ever fires.
  //
  // `onShowFiles` is the same shape of signal for the file-activity rail: the
  // host passes it only while the rail is CLOSED **and could actually open**
  // (its placement/width gate), so the "Files · N" pill is purely a reopen
  // affordance — it never competes with a rail already on screen, and never
  // offers to open one that can't appear. `filesCount > 0` keeps it off a
  // session that touched nothing.
  import Folder from '@lucide/svelte/icons/folder';
  import Archive from '@lucide/svelte/icons/archive';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
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
    deleting = false,
    onArchive,
    onDelete,
    onOpenFile,
    filesCount = 0,
    onShowFiles
  }: {
    icmName: string | null;
    mountKey: string | null;
    ended: boolean;
    archiving: boolean;
    deleting?: boolean;
    onArchive?: () => void;
    onDelete?: () => void;
    onOpenFile?: (sel: { mountKey: string; path: string }) => void;
    filesCount?: number;
    onShowFiles?: () => void;
  } = $props();

  let treeOpen = $state(false);
  let menuOpen = $state(false);
  // Delete is irreversible — the menu item arms a confirm row instead of
  // firing directly; closing the popover always disarms it.
  let confirmingDelete = $state(false);

  $effect(() => {
    if (!menuOpen) confirmingDelete = false;
  });
  // `icmStore.groups` is keyed by `mount` (the stable mount key) — the same
  // key sessions carry as `icmMount`. Folders inside the popover lazy-load
  // through `IcmTree`'s own `loadDir` calls; the mount's ROOT level is the
  // caller's concern (see `ChatView`'s tree-load effect).
  const treeNav = $derived(icmToNav(icmStore.groups.find((g) => g.mount === mountKey)?.tree ?? []));
  const canBrowse = $derived(Boolean(onOpenFile && mountKey));
</script>

{#if icmName || onArchive || onDelete}
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
    {#if onShowFiles && filesCount > 0}
      <!-- id: the rail's close button hands keyboard focus here after it
           unmounts itself (ChatView.closeRail). min-h-8/-my-1: ≥32px hit
           target without growing the header bar. -->
      <button
        id="session-files-pill"
        type="button"
        onclick={onShowFiles}
        class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading focus-visible:ring-ring/50 -my-1 min-h-8 shrink-0 rounded-md px-1.5 text-[11.5px] whitespace-nowrap transition-colors outline-none focus-visible:ring-2"
      >
        Files · {filesCount}
      </button>
    {/if}
    {#if onArchive || onDelete}
      <Popover.Root bind:open={menuOpen}>
        <Popover.Trigger
          aria-label="Session actions"
          title="More"
          class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading data-[state=open]:bg-paper-pill flex size-6 shrink-0 items-center justify-center rounded-md transition-colors"
        >
          <Ellipsis class="size-4" strokeWidth={1.5} aria-hidden="true" />
        </Popover.Trigger>
        <Popover.Content align="end" class="w-56 p-1">
          {#if onArchive}
            <button
              type="button"
              disabled={archiving}
              onclick={() => {
                menuOpen = false;
                onArchive();
              }}
              class="text-ink-secondary hover:bg-paper-pill hover:text-ink-heading flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12.5px] transition-colors disabled:opacity-50"
            >
              <Archive class="size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
              {archiving ? 'Archiving…' : ended ? 'Archive' : 'Stop & archive'}
            </button>
          {/if}
          {#if onDelete}
            {#if confirmingDelete}
              <div class="flex flex-col gap-1.5 px-2 py-1.5">
                <p class="text-ink-body text-[12px]">Delete this session permanently? There is no archived copy.</p>
                <div class="flex items-center gap-1.5">
                  <button
                    type="button"
                    disabled={deleting}
                    onclick={() => {
                      menuOpen = false;
                      onDelete();
                    }}
                    class="text-warn-ink border-paper-border hover:bg-paper-pill rounded-md border px-2 py-1 text-[12px] font-medium transition-colors disabled:opacity-50"
                  >
                    {deleting ? 'Deleting…' : 'Delete'}
                  </button>
                  <button
                    type="button"
                    onclick={() => (confirmingDelete = false)}
                    class="text-ink-meta hover:text-ink-heading rounded-md px-2 py-1 text-[12px] transition-colors"
                  >
                    Cancel
                  </button>
                </div>
              </div>
            {:else}
              <button
                type="button"
                disabled={deleting}
                onclick={() => (confirmingDelete = true)}
                class="text-warn-ink hover:bg-paper-pill flex w-full items-center gap-2 rounded-md px-2 py-1.5 text-left text-[12.5px] transition-colors disabled:opacity-50"
              >
                <Trash2 class="size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                {ended ? 'Delete…' : 'Stop & delete…'}
              </button>
            {/if}
          {/if}
        </Popover.Content>
      </Popover.Root>
    {/if}
  </div>
{/if}
