<script lang="ts">
  // Sidebar workspace switcher — sits above the StatusPill. Trigger shows
  // the current workspace's folder name (basename of its path, mono 11px)
  // with a chevron; opens a shadcn/bits-ui DropdownMenu listing recent
  // workspaces (current one checked).
  //
  // The manual "Open another folder…" path entry was removed here: Task 2.5
  // made `open_workspace` resolve strictly by registry id
  // (`Manager.open/1` → `Config.workspace_by_id/1`), so typing an arbitrary
  // folder path always failed with `unknown_workspace`. The full id-based
  // switcher rework (adding a folder picker back, wired to id resolution)
  // is Phase 10 — this is just removing the broken affordance early.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Check from '@lucide/svelte/icons/check';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let {
    onBeforeMutateActive
  }: {
    /**
     * Same hook `Sidebar`/`AppFrame` forward to `IcmTree` for rename/delete
     * flushes — reused here so switching workspaces flushes a pending
     * debounced edit on the currently open page first. See
     * `workspaceStore.switchTo`'s doc comment.
     */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  let menuOpen = $state(false);
  let switching = $state(false);
  let error = $state<string | null>(null);

  const currentName = $derived(workspaceStore.name ?? 'Workspace');

  function mapError(code: string): string {
    // Mirrors RenameDialog's flush-failure copy (`before-mutate.ts`'s
    // `unsaved_changes` is the same error code both surface) — one voice
    // for "your pending edit didn't make it, fix that first" across the app.
    if (code === 'unsaved_changes') {
      return "Couldn't save your latest changes. Fix that first, then try again.";
    }
    return "Couldn't open this workspace. Try again.";
  }

  async function selectWorkspace(id: string): Promise<void> {
    const trimmed = id.trim();
    if (!trimmed) return;

    if (trimmed === workspaceStore.id) {
      menuOpen = false;
      return;
    }

    error = null;
    switching = true;
    const result = await workspaceStore.switchTo(trimmed, onBeforeMutateActive);
    switching = false;

    if (!result.ok) {
      error = mapError(result.error);
      return;
    }

    menuOpen = false;
  }
</script>

<div class="flex flex-col gap-1.5">
  <DropdownMenu.Root bind:open={menuOpen}>
    <DropdownMenu.Trigger>
      {#snippet child({ props })}
        <button
          type="button"
          {...props}
          class="flex w-full items-center justify-between gap-1.5 rounded-md px-2 py-1.5 text-left transition-colors hover:bg-paper-pill data-[state=open]:bg-paper-pill"
        >
          <span class="truncate font-mono text-[11px] text-ink-secondary">{currentName}</span>
          <ChevronDown class="size-3 shrink-0 text-ink-meta" strokeWidth={1.5} />
        </button>
      {/snippet}
    </DropdownMenu.Trigger>
    <DropdownMenu.Content align="start" class="w-64">
      {#if workspaceStore.recent.length > 0}
        {#each workspaceStore.recent as ws (ws.id)}
          {@const current = ws.id === workspaceStore.id}
          <DropdownMenu.Item
            aria-current={current ? 'true' : undefined}
            aria-disabled={switching ? 'true' : undefined}
            onSelect={(event) => {
              event.preventDefault();
              if (switching) return;
              void selectWorkspace(ws.id);
            }}
          >
            <span class="flex size-3.5 shrink-0 items-center justify-center">
              {#if current}
                <Check class="size-3.5" strokeWidth={1.5} />
              {/if}
            </span>
            <span class="flex min-w-0 flex-col">
              <span class="truncate text-[12.5px] text-ink-heading">{ws.name}</span>
            </span>
          </DropdownMenu.Item>
        {/each}
      {/if}
    </DropdownMenu.Content>
  </DropdownMenu.Root>

  {#if error}
    <p role="alert" class="text-[11.5px] text-warn-ink">{error}</p>
  {/if}
</div>
