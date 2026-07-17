<script lang="ts">
  // Folder strip for the mail list pane (mail design spec E §UI): one row
  // per mirrored folder from `list_mail_folders`, selected folder
  // highlighted, held folders badged "held" (spec §folder lifecycle —
  // held means the engine stopped syncing it pending a user decision;
  // the discard affordance lives in SetupPanel, not here). Message counts
  // right-aligned, muted.
  import { mailStore } from '$lib/stores/mail.svelte';
  import { folderBadge } from './mail-shapes';
</script>

{#if mailStore.folders.length > 0}
  <ul class="flex flex-col gap-0.5" aria-label="Mail folders">
    {#each mailStore.folders as folder (folder.name)}
      {@const selected = folder.name === mailStore.selectedFolder}
      {@const badge = folderBadge(folder)}
      <li>
        <button
          type="button"
          class="hover:bg-paper-pill flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-[12.5px] transition-colors"
          class:bg-paper-pill={selected}
          class:text-ink-heading={selected}
          class:text-ink-secondary={!selected}
          onclick={() => void mailStore.selectFolder(folder.name)}
        >
          <span class="min-w-0 flex-1 truncate">{folder.name}</span>
          {#if badge}
            <span class="text-warn-ink shrink-0 text-[10.5px] tracking-[0.06em] uppercase">{badge}</span>
          {/if}
          <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">{folder.messageCount}</span>
        </button>
      </li>
    {/each}
  </ul>
{/if}
