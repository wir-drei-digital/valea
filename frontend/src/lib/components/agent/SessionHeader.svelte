<script lang="ts">
  // The chat session's header line: which ICM the session works in, an
  // archive affordance, and the file-activity pill.
  //
  // Presentational: every piece of state (which ICM, whether the session
  // ended, whether an archive call is in flight) arrives as a prop, so the
  // same header renders for a route primary and for a session inside a pane.
  //
  // It carried a popover FILE TREE here, on the folder name. That is retired:
  // the tree is a pane now (`FilesPane`), reachable from the bar's ＋ Pane
  // beside any chat, where it is a real browser with rename, delete, two
  // splits and persistent expansion rather than a menu that closed on every
  // click. The folder line is a plain label again.
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
  import type { Snippet } from 'svelte';
  import Folder from '@lucide/svelte/icons/folder';
  import Archive from '@lucide/svelte/icons/archive';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import * as Popover from '$lib/components/ui/popover';

  let {
    icmName,
    mountKey,
    ended,
    archiving,
    deleting = false,
    onArchive,
    onDelete,
    filesCount = 0,
    onShowFiles,
    filesPanel
  }: {
    icmName: string | null;
    mountKey: string | null;
    ended: boolean;
    archiving: boolean;
    deleting?: boolean;
    onArchive?: () => void;
    onDelete?: () => void;
    filesCount?: number;
    onShowFiles?: () => void;
    /**
     * Mutually exclusive with `onShowFiles` (the host picks per layout):
     * when the inline rail cannot fit — narrow view, side-pane placement —
     * the pill becomes a popover trigger and this snippet is its content
     * (the host renders the rail's popover variant). The file-activity
     * affordance never disappears with the layout; it defers.
     */
    filesPanel?: Snippet;
  } = $props();

  let menuOpen = $state(false);
  // Delete is irreversible — the menu item arms a confirm row instead of
  // firing directly; closing the popover always disarms it.
  let confirmingDelete = $state(false);

  $effect(() => {
    if (!menuOpen) confirmingDelete = false;
  });
</script>

{#if icmName || onArchive || onDelete}
  <div class="border-paper-hairline flex items-center gap-1.5 border-b px-4 pb-2">
    {#if icmName}
      <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
      <span class="text-ink-meta text-[12px]">
        Working in <span class="text-ink-secondary font-medium">{icmName}</span>
      </span>
    {/if}
    <span class="min-w-0 flex-1" aria-hidden="true"></span>
    {#if filesCount > 0 && (onShowFiles || filesPanel)}
      {#if filesPanel}
        <!-- Popover mode: the inline rail can't fit here, so the same pill
             opens the file list as a popover instead of vanishing with the
             layout. No id — the inline pill elsewhere on the page owns it. -->
        <Popover.Root>
          <Popover.Trigger
            class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading focus-visible:ring-ring/50 data-[state=open]:bg-paper-pill -my-1 min-h-8 shrink-0 rounded-md px-1.5 text-[11.5px] whitespace-nowrap transition-colors outline-none focus-visible:ring-2"
          >
            Context · {filesCount}
          </Popover.Trigger>
          <Popover.Content align="end" class="w-[316px] p-2">
            {@render filesPanel()}
          </Popover.Content>
        </Popover.Root>
      {:else}
        <!-- id: the rail's close button hands keyboard focus here after it
             unmounts itself (ChatView.closeRail). min-h-8/-my-1: ≥32px hit
             target without growing the header bar. -->
        <button
          id="session-files-pill"
          type="button"
          onclick={onShowFiles}
          class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading focus-visible:ring-ring/50 -my-1 min-h-8 shrink-0 rounded-md px-1.5 text-[11.5px] whitespace-nowrap transition-colors outline-none focus-visible:ring-2"
        >
          Context · {filesCount}
        </button>
      {/if}
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
