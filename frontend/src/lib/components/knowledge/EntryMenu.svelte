<script lang="ts">
  // Overflow (⋯) menu for a single tree/list row — Rename / Delete. Self
  // contained: owns its own dropdown state and mounts the two dialogs, so
  // callers just drop `<EntryMenu {path} {name} {kind} />` next to a row
  // (as a SIBLING of the row's link/button, never nested inside it — an
  // interactive control inside an <a> is invalid HTML and breaks the row's
  // own click target).
  //
  // Every `kind` gets Rename and Delete — including a non-.md `file`, whose
  // backend rename now preserves the extension it was given rather than
  // coercing `.md` (`Valea.ICM.rename_target_name/3`). Kind changes the
  // WORDS (see `entry-kind.ts`) and one gate: the session action needs a
  // single file to hand the agent, so folders don't get it.
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
  import { chatNewHref } from '$lib/panes/pane-route';
  import { startSessionLabel, type EntryKind } from './entry-kind';

  let {
    mountKey,
    path,
    name,
    kind,
    class: className = '',
    onBeforeMutate,
    onDeleted
  }: {
    mountKey: string;
    path: string;
    name: string;
    kind: EntryKind;
    class?: string;
    /**
     * Forwarded to RenameDialog/DeleteDialog. Only passed by callers for the
     * row that IS the currently open page (e.g. the sidebar tree's active
     * entry) — other rows have no pending edit to flush, so they pass
     * nothing and the dialogs skip straight to the mutate call.
     */
    onBeforeMutate?: () => Promise<void>;
    /**
     * Forwarded to DeleteDialog: this entry was deleted. For callers holding
     * state keyed by position in a list of open files — the Files pane's
     * auto-open claim — because `followMutation` renumbers those lists in the
     * URL and nothing else tells the holder it happened.
     */
    onDeleted?: () => void;
  } = $props();

  let menuOpen = $state(false);
  let renameOpen = $state(false);
  let deleteOpen = $state(false);

  /**
   * "Start a session with this page/file" (Spec D §B) — leaf rows of either
   * kind, never folders.
   *
   * Spec 2026-08-02: no session is created here any more, and no canned
   * opening prompt is sent. It navigates to `/chat`'s new-session composer
   * with this entry ATTACHED and nothing sent, so the user's first turn is
   * their own instruction ("this is a new invoice, document it in my ICM")
   * rather than an answer to a question nobody asked. `ChatView` creates the
   * session on send — including resolving the ICM id for the `context_doc`
   * grant — so abandoning the composer leaves nothing behind.
   *
   * `goto` rather than a pane, because this menu is rendered from `IcmTree`
   * — the sidebar — which appears on routes with no pane wiring at all.
   *
   * `chatNewHref` writes the URL: the origin needs a second encode layer on
   * the way into a query value, and a single codec shared with the pane
   * param is what keeps the route and a pane from reading an origin
   * differently. Non-.md files ride the identical path — only the origin's
   * `kind` forks, and it is display/premise wording, never a grant.
   */
  function startSessionWithEntry(): void {
    void goto(
      chatNewHref({
        kind: 'chat-new',
        mountKey,
        from: { kind: kind === 'file' ? 'file' : 'page', path, label: name }
      })
    );
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
    {#if kind !== 'folder'}
      <DropdownMenu.Item onSelect={() => startSessionWithEntry()}>
        <MessageSquarePlus class="size-3.5" strokeWidth={1.5} />
        {startSessionLabel(kind)}
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

<RenameDialog {mountKey} {path} currentName={name} {kind} bind:open={renameOpen} {onBeforeMutate} />
<DeleteDialog {mountKey} {path} {name} {kind} bind:open={deleteOpen} {onBeforeMutate} {onDeleted} />
