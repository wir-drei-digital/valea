<script lang="ts">
  // Sidebar workspace switcher — sits above the StatusPill. Trigger shows
  // the current workspace's folder name (basename of its path, mono 11px)
  // with a chevron; opens a shadcn/bits-ui DropdownMenu listing recent
  // workspaces (current one checked) plus "Open another folder…".
  //
  // The "Open another folder…" path input is deliberately rendered OUTSIDE
  // `DropdownMenu.Content` (selecting the item closes the menu and reveals
  // a small panel below the trigger instead) rather than inline inside the
  // open menu: bits-ui's menu content wires a raw keydown handler that
  // typeahead-searches on every single character key while focus is
  // anywhere inside the content (see `DOMTypeahead.handleTypeaheadSearch`
  // in `bits-ui/dist/internal/dom-typeahead.svelte.js`), with no guard for
  // the key event's target being a text input — so a live `<Input>` nested
  // inside `DropdownMenu.Content` has every keystroke hijacked into
  // menu-item matching (which calls `.focus()` on whatever item matches,
  // yanking focus out of the field). Closing the menu first sidesteps that
  // entirely while keeping the same reveal-a-path-input-and-Open-button
  // shape the brief and `OpenWorkspaceFlow.svelte` (onboarding) both use.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
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
  let formOpen = $state(false);
  let manualPath = $state('');
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
      formOpen = false;
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
    formOpen = false;
    manualPath = '';
  }

  function openForm(): void {
    formOpen = true;
    error = null;
  }

  function closeForm(): void {
    formOpen = false;
    manualPath = '';
    error = null;
  }
</script>

<div class="flex flex-col gap-1.5">
  <DropdownMenu.Root
    bind:open={menuOpen}
    onOpenChange={(open) => {
      if (!open) closeForm();
    }}
  >
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
            onSelect={(event) => {
              event.preventDefault();
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
        <DropdownMenu.Separator />
      {/if}
      <DropdownMenu.Item
        onSelect={(event) => {
          event.preventDefault();
          menuOpen = false;
          openForm();
        }}
      >
        Open another folder…
      </DropdownMenu.Item>
    </DropdownMenu.Content>
  </DropdownMenu.Root>

  {#if formOpen}
    <div class="flex flex-col gap-2 rounded-lg border border-paper-border bg-paper-card p-2.5">
      <Input
        bind:value={manualPath}
        disabled={switching}
        placeholder="/Users/you/Documents/my-business"
        onkeydown={(event) => {
          if (event.key === 'Enter') {
            event.preventDefault();
            void selectWorkspace(manualPath);
          }
        }}
      />
      <div class="flex gap-2">
        <Button type="button" size="sm" class="flex-1" onclick={() => void selectWorkspace(manualPath)} disabled={switching || !manualPath.trim()}>
          {switching ? 'Opening…' : 'Open'}
        </Button>
        <Button type="button" variant="outline" size="sm" onclick={closeForm} disabled={switching}>Cancel</Button>
      </div>
    </div>
  {/if}

  {#if error}
    <p role="alert" class="text-[11.5px] text-warn-ink">{error}</p>
  {/if}
</div>
