<script lang="ts">
  // Overflow (⋯) menu for a single tree/list row — Rename / Delete. Self
  // contained: owns its own dropdown state and mounts the two dialogs, so
  // callers just drop `<EntryMenu {path} {name} {isFolder} />` next to a row
  // (as a SIBLING of the row's link/button, never nested inside it — an
  // interactive control inside an <a> is invalid HTML and breaks the row's
  // own click target).
  //
  // Hover-revealed via the parent's `group` class, but never hidden from
  // keyboard focus (`group-focus-within` / `focus-visible` / open-state all
  // force it visible) — a mouse-only affordance would make rename/delete
  // unreachable by keyboard.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import Pencil from '@lucide/svelte/icons/pencil';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import RenameDialog from './RenameDialog.svelte';
  import DeleteDialog from './DeleteDialog.svelte';

  let {
    mountKey,
    path,
    name,
    isFolder,
    class: className = '',
    onBeforeMutate
  }: {
    mountKey: string;
    path: string;
    name: string;
    isFolder: boolean;
    class?: string;
    /**
     * Forwarded to RenameDialog/DeleteDialog. Only passed by callers for the
     * row that IS the currently open page (e.g. the sidebar tree's active
     * entry) — other rows have no pending edit to flush, so they pass
     * nothing and the dialogs skip straight to the mutate call.
     */
    onBeforeMutate?: () => Promise<void>;
  } = $props();

  let menuOpen = $state(false);
  let renameOpen = $state(false);
  let deleteOpen = $state(false);
</script>

<DropdownMenu.Root bind:open={menuOpen}>
  <DropdownMenu.Trigger>
    {#snippet child({ props })}
      <button
        type="button"
        {...props}
        aria-label={`Actions for ${name}`}
        class={[
          'flex size-8 shrink-0 items-center justify-center rounded-md text-ink-meta transition-colors hover:bg-paper-card hover:text-ink-heading',
          'opacity-0 group-hover:opacity-100 group-focus-within:opacity-100 focus-visible:opacity-100 data-[state=open]:opacity-100 data-[state=open]:bg-paper-card',
          className
        ]}
      >
        <Ellipsis class="size-4" strokeWidth={1.5} />
      </button>
    {/snippet}
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="end">
    <DropdownMenu.Item onSelect={() => (renameOpen = true)}>
      <Pencil class="size-3.5" strokeWidth={1.5} />
      Rename
    </DropdownMenu.Item>
    <DropdownMenu.Item variant="destructive" onSelect={() => (deleteOpen = true)}>
      <Trash2 class="size-3.5" strokeWidth={1.5} />
      Delete…
    </DropdownMenu.Item>
  </DropdownMenu.Content>
</DropdownMenu.Root>

<RenameDialog {mountKey} {path} currentName={name} {isFolder} bind:open={renameOpen} {onBeforeMutate} />
<DeleteDialog {mountKey} {path} {name} {isFolder} bind:open={deleteOpen} {onBeforeMutate} />
