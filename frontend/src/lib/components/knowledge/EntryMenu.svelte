<script lang="ts">
  // Actions menu for a single tree/list row, in one of two shells. Self
  // contained: owns its own menu state and mounts the dialogs, so callers
  // just drop `<EntryMenu {path} {name} {kind} />` (dropdown, the `⋯`
  // button) or wrap a row in `<EntryMenu variant="context">…row…</EntryMenu>`
  // (right-click, anywhere on the row). Both shells render the SAME item
  // list — `entry-actions.ts` — so there is exactly one place that decides
  // what a row offers; this component only decides how it's reached and
  // what each item DOES when picked.
  //
  // The dropdown's trigger button is a SIBLING of the row's link/button,
  // never nested inside it — an interactive control inside an <a> is
  // invalid HTML and breaks the row's own click target. The context variant
  // instead wraps the row as `children`, since a right-click needs the row
  // itself as the hit target rather than a dedicated trigger control.
  //
  // Hover-revealed via the parent's `group` class (dropdown only — the
  // context menu has no visible trigger to reveal), but never hidden from
  // keyboard focus (`group-focus-within` / `focus-visible` / open-state all
  // force it visible) — a mouse-only affordance would make rename/delete
  // unreachable by keyboard.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import * as ContextMenu from '$lib/components/ui/context-menu/index.js';
  import type { Snippet } from 'svelte';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import Pencil from '@lucide/svelte/icons/pencil';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import MessageSquarePlus from '@lucide/svelte/icons/message-square-plus';
  import FolderPlus from '@lucide/svelte/icons/folder-plus';
  import FilePlus from '@lucide/svelte/icons/file-plus';
  import FolderOpen from '@lucide/svelte/icons/folder-open';
  import Copy from '@lucide/svelte/icons/copy';
  import SquarePlus from '@lucide/svelte/icons/square-plus';
  import RenameDialog from './RenameDialog.svelte';
  import DeleteDialog from './DeleteDialog.svelte';
  import NewEntryDialog from './NewEntryDialog.svelte';
  import { goto } from '$app/navigation';
  import { chatNewHref } from '$lib/panes/pane-route';
  import type { EntryKind } from './entry-kind';
  import { entryActions, type EntryActionId } from './entry-actions';
  import { absPathFor, canRevealInOs, revealInOs, revealLabel } from '$lib/shell/reveal-in-os';
  import { mountsStore } from '$lib/stores/mounts.svelte';

  let {
    mountKey,
    path,
    name,
    kind,
    class: className = '',
    onBeforeMutate,
    onDeleted,
    variant = 'dropdown',
    onOpenInTab,
    openInTabDisabled = null,
    children
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
    /**
     * Which shell renders the list. `'dropdown'` is the `⋯` overflow button
     * this component has always been; `'context'` wraps `children` (the row
     * itself) so a right-click anywhere on it opens the SAME items.
     *
     * bits-ui's ContextMenu and DropdownMenu expose matching
     * Root/Trigger/Content/Item/Separator surfaces, so the item list is
     * written once and the primitive family is picked below.
     */
    variant?: 'dropdown' | 'context';
    /** "Open in a new tab" — omitted entirely by hosts that have no tabs. */
    onOpenInTab?: () => void;
    /** Why it cannot act, or null when it can. See `entry-actions.ts`. */
    openInTabDisabled?: string | null;
    /** The row, for `variant: 'context'`. Unused by the dropdown variant. */
    children?: Snippet;
  } = $props();

  let menuOpen = $state(false);
  let renameOpen = $state(false);
  let deleteOpen = $state(false);
  let newPageOpen = $state(false);
  let newFolderOpen = $state(false);

  const actions = $derived(
    entryActions({
      kind,
      canReveal: canRevealInOs(),
      revealLabel: revealLabel(),
      canOpenInTab: onOpenInTab !== undefined,
      openInTabDisabled
    })
  );

  /**
   * Where "New page here" / "New folder here" put the new entry: INSIDE a
   * folder row, ALONGSIDE a leaf. `NewEntryDialog` takes a parent path, and
   * "here" means the same thing to a user in both cases — next to what they
   * right-clicked.
   */
  const parentPath = $derived.by(() => {
    if (kind === 'folder') return path;
    const cut = path.lastIndexOf('/');
    return cut === -1 ? '' : path.slice(0, cut);
  });

  /** Best-effort — a clipboard the browser refuses is not worth a dialog. */
  function copy(text: string): void {
    void navigator.clipboard?.writeText(text).catch(() => {});
  }

  function reveal(): void {
    const abs = absPathFor(mountsStore.mounts, mountKey, path);
    if (abs) revealInOs(abs);
  }

  function run(id: EntryActionId): void {
    switch (id) {
      case 'open-in-tab':
        if (!openInTabDisabled) onOpenInTab?.();
        break;
      case 'start-session':
        startSessionWithEntry();
        break;
      case 'reveal':
        reveal();
        break;
      case 'copy-path':
        copy(path);
        break;
      case 'copy-name':
        copy(name);
        break;
      case 'new-page':
        newPageOpen = true;
        break;
      case 'new-folder':
        newFolderOpen = true;
        break;
      case 'rename':
        renameOpen = true;
        break;
      case 'delete':
        deleteOpen = true;
        break;
    }
  }

  const ICONS: Record<EntryActionId, typeof Pencil> = {
    'open-in-tab': SquarePlus,
    'start-session': MessageSquarePlus,
    reveal: FolderOpen,
    'copy-path': Copy,
    'copy-name': Copy,
    'new-page': FilePlus,
    'new-folder': FolderPlus,
    rename: Pencil,
    delete: Trash2
  };

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

{#snippet items(Menu: typeof DropdownMenu | typeof ContextMenu)}
  {#each actions as action, i (i)}
    {#if action.kind === 'separator'}
      <Menu.Separator />
    {:else}
      {@const Icon = ICONS[action.id]}
      <!-- `aria-disabled` + a title, never the `disabled` attribute: a truly
           disabled item takes no pointer events, so its reason never appears
           on hover — which turns "disabled, and here's why" back into the
           silent no-op the reason exists to replace. Same rule the row's own
           "Open in a new tab" button follows. -->
      <Menu.Item
        variant={action.destructive ? 'destructive' : undefined}
        aria-disabled={action.disabledReason ? 'true' : undefined}
        title={action.disabledReason ?? undefined}
        onSelect={() => run(action.id)}
      >
        <Icon class="size-3.5" strokeWidth={1.5} />
        {action.label}
      </Menu.Item>
    {/if}
  {/each}
{/snippet}

{#if variant === 'context'}
  <ContextMenu.Root>
    <ContextMenu.Trigger>{@render children?.()}</ContextMenu.Trigger>
    <ContextMenu.Content class="w-[220px]">{@render items(ContextMenu)}</ContextMenu.Content>
  </ContextMenu.Root>
{:else}
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
    <DropdownMenu.Content align="end" class="w-[220px]">
      {@render items(DropdownMenu)}
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}

<RenameDialog {mountKey} {path} currentName={name} {kind} bind:open={renameOpen} {onBeforeMutate} />
<DeleteDialog {mountKey} {path} {name} {kind} bind:open={deleteOpen} {onBeforeMutate} {onDeleted} />
<NewEntryDialog mode="page" {mountKey} {parentPath} bind:open={newPageOpen} />
<NewEntryDialog mode="folder" {mountKey} {parentPath} bind:open={newFolderOpen} />
