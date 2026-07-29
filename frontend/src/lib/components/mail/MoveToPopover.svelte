<script lang="ts">
  // "Move to…" for the read pane's action row — `FolderPicker`'s popover
  // pattern (bits-ui trigger, one row per folder with its count right-aligned
  // and muted) over the folders a message may actually be filed into. The
  // trigger is a `Button` via the `child` snippet rather than FolderPicker's
  // quiet row, because here it stands among Archive/Flag/Delete and must
  // match them (same pattern as `NewEntryButton`).
  //
  // Presentational and callback-driven, like `SessionPickerPopover`: it
  // renders the targets it is handed and reports the pick. The `move` op, its
  // busy flag and its error line all stay in `MessageView`, next to every
  // other op the pane applies.
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import * as Popover from '$lib/components/ui/popover';
  import { Button } from '$lib/components/ui/button/index.js';
  import type { MailFolder } from '$lib/stores/mail.svelte';

  let {
    targets,
    disabled = false,
    onMove
  }: {
    /** Already filtered by `moveTargets` — this component excludes nothing of its own. */
    targets: MailFolder[];
    disabled?: boolean;
    onMove: (folder: string) => void;
  } = $props();

  let open = $state(false);
</script>

{#if targets.length > 0}
  <Popover.Root bind:open>
    <!-- `disabled` belongs on the TRIGGER, not on the button in the snippet:
         bits-ui always emits its own `disabled` in the merged props, so a
         value set on the button would be spread right back over. -->
    <Popover.Trigger {disabled}>
      {#snippet child({ props })}
        <Button type="button" variant="ghost" {...props}>
          Move to
          <ChevronDown class="text-ink-meta" aria-hidden="true" />
        </Button>
      {/snippet}
    </Popover.Trigger>
    <Popover.Content align="start" class="max-h-80 w-64 overflow-y-auto p-1">
      <ul class="flex flex-col gap-0.5" aria-label="Move to folder">
        {#each targets as folder (folder.name)}
          <li>
            <button
              type="button"
              class="hover:bg-paper-pill text-ink-secondary flex w-full items-center gap-1.5 rounded-md px-2 py-1 text-left text-[12.5px] transition-colors"
              onclick={() => {
                open = false;
                onMove(folder.name);
              }}
            >
              <span class="min-w-0 flex-1 truncate">{folder.name}</span>
              <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">{folder.messageCount}</span>
            </button>
          </li>
        {/each}
      </ul>
    </Popover.Content>
  </Popover.Root>
{/if}
