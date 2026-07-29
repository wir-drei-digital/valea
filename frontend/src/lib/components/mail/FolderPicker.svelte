<script lang="ts">
  // Folder selector for the mail list pane — a popover over the mirrored
  // folders from `list_mail_folders`, replacing the old always-open
  // FolderList strip. Same trigger/content pattern as the chat header's
  // file-tree popover (`SessionHeader.svelte`): quiet trigger row naming the
  // current selection, chevron, popover list underneath. Held folders stay
  // badged "held" (spec §folder lifecycle — the discard affordance lives in
  // SetupPanel, not here); message counts right-aligned, muted.
  import Folder from '@lucide/svelte/icons/folder';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Check from '@lucide/svelte/icons/check';
  import * as Popover from '$lib/components/ui/popover';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { folderBadge } from './mail-shapes';

  let open = $state(false);

  const selected = $derived(
    mailStore.folders.find((folder) => folder.name === mailStore.selectedFolder) ?? null
  );
</script>

{#if mailStore.folders.length > 0}
  <Popover.Root bind:open>
    <Popover.Trigger
      aria-label="Mail folder"
      class="hover:bg-paper-pill data-[state=open]:bg-paper-pill -mx-1 flex items-center gap-1.5 rounded-md px-1.5 py-1 transition-colors"
    >
      <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
      <span class="text-ink-secondary min-w-0 truncate text-[12.5px] font-medium">
        {mailStore.selectedFolder ?? 'INBOX'}
      </span>
      {#if selected}
        <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">{selected.messageCount}</span>
      {/if}
      <ChevronDown class="text-ink-meta size-3 shrink-0" strokeWidth={1.5} aria-hidden="true" />
    </Popover.Trigger>
    <Popover.Content align="start" class="max-h-80 w-64 overflow-y-auto p-1">
      <ul class="flex flex-col gap-0.5" aria-label="Mail folders">
        {#each mailStore.folders as folder (folder.name)}
          {@const isSelected = folder.name === mailStore.selectedFolder}
          {@const badge = folderBadge(folder)}
          <li>
            <button
              type="button"
              class="hover:bg-paper-pill flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-[12.5px] transition-colors"
              class:text-ink-heading={isSelected}
              class:text-ink-secondary={!isSelected}
              onclick={() => {
                open = false;
                void mailStore.selectFolder(folder.name);
              }}
            >
              <span class="flex size-3.5 shrink-0 items-center justify-center" aria-hidden="true">
                {#if isSelected}
                  <Check class="size-3.5" strokeWidth={2} />
                {/if}
              </span>
              <span class="min-w-0 flex-1 truncate">{folder.name}</span>
              {#if badge}
                <span class="text-warn-ink shrink-0 text-[10.5px] tracking-[0.06em] uppercase">{badge}</span>
              {/if}
              <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">{folder.messageCount}</span>
            </button>
          </li>
        {/each}
      </ul>
    </Popover.Content>
  </Popover.Root>
{/if}
