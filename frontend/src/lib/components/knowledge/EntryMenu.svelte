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
  import MessageSquarePlus from '@lucide/svelte/icons/message-square-plus';
  import RenameDialog from './RenameDialog.svelte';
  import DeleteDialog from './DeleteDialog.svelte';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { setInitialPrompt, pageSessionPrompt } from '$lib/stores/initial-prompt';

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
  let sessionError = $state<string | null>(null);

  /**
   * "Start a session with this page" (Spec D §B) — page rows only. Mints a
   * session pre-loaded with this page as a `context_doc` grant (Task 9's
   * `api.createAgentSession` `opts.contextDoc`), stashes the opening prompt
   * under the new session id (`initial-prompt.ts`'s one-shot handoff — the
   * chat route takes it and `AgentSessionStore` fires it as the first user
   * turn on join), and navigates there. Same refresh-then-navigate order as
   * `IcmProjects.svelte`'s `startSession`, so the sidebar's recent-sessions
   * list is current by the time the chat route's own list renders.
   */
  async function startSessionWithPage() {
    sessionError = null;
    const icmId = mountsStore.mounts.find((m) => m.mountKey === mountKey)?.id;
    if (!icmId) {
      sessionError = 'This ICM has no loadable identity — run Diagnose from the sidebar.';
      return;
    }
    const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0, {
      contextDoc: { kind: 'icm', icm_id: icmId, path }
    });
    if (!result.ok) {
      sessionError = `Couldn't start the session (${result.error}).`;
      return;
    }
    const data = result.data as { id: string };
    setInitialPrompt(data.id, pageSessionPrompt(path));
    await recentSessionsStore.refresh();
    void goto(`/chat?session=${data.id}`);
  }
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
    {#if !isFolder}
      <DropdownMenu.Item onSelect={() => void startSessionWithPage()}>
        <MessageSquarePlus class="size-3.5" strokeWidth={1.5} />
        Start a session with this page
      </DropdownMenu.Item>
    {/if}
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

{#if sessionError}
  <p role="alert" class="text-warn-ink text-[12.5px]">{sessionError}</p>
{/if}

<RenameDialog {mountKey} {path} currentName={name} {isFolder} bind:open={renameOpen} {onBeforeMutate} />
<DeleteDialog {mountKey} {path} {name} {isFolder} bind:open={deleteOpen} {onBeforeMutate} />
