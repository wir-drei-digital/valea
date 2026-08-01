<script lang="ts">
  import type { NavTreeItem } from '$lib/shell/nav';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import SquarePlus from '@lucide/svelte/icons/square-plus';
  import IcmTree from './IcmTree.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';
  import { fileLeafLabel } from '$lib/components/knowledge/file-leaf';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';

  let {
    nodes,
    activePaths = [],
    currentPath = null,
    linkSearch = '',
    entryMenus,
    onBeforeMutate,
    onDeleted,
    onSelect,
    onOpenInTab,
    openInTabDisabled = null
  }: {
    nodes: NavTreeItem[];
    /**
     * EVERY open href, not "the one open page" (composable views): a Files
     * pane holds up to six tabs at once, and every one of their rows has to
     * read as open. A single active path stopped being expressible the moment
     * a pane could show more than one file, so this replaced the old
     * `activePath` string rather than sitting beside it.
     */
    activePaths?: string[];
    /**
     * Of those, the one being READ — the active tab. Marked more strongly than
     * the rest and the only row that carries `aria-current`, because "six
     * files are open" and "this is the one on screen" are different facts and
     * a tree that renders them identically answers neither.
     */
    currentPath?: string | null;
    /**
     * Query string appended to every leaf link's `href` (side-panes pass —
     * e.g. `?pane=chat:<id>`): browsing the tree with a chat pane open keeps
     * the pane, instead of every file click silently closing it. Appended to
     * the RENDERED href only — `node.href` itself stays the bare path, so
     * `activePaths` comparisons and `treeOpenState`'s per-href keys are
     * unaffected (a pane opening/closing must not collapse the tree).
     * `knowledgeHref` never carries a query of its own, so a plain `?…`
     * suffix is safe.
     */
    linkSearch?: string;
    /**
     * Whether rows carry their rename/delete overflow menu. Defaults to
     * "yes, unless this is a picker" — i.e. `onSelect === undefined`.
     *
     * The default alone used to be the whole rule, and it stopped being
     * enough when `FilesPane` arrived: it is a full file BROWSER that
     * nonetheless drives selection through `onSelect`, because a click
     * inside a pane rewrites that pane's descriptor instead of navigating.
     * Popover pickers (compose's attach, the session header's file picker)
     * still leave this unset and still get no menus — picking a file is not
     * the place to rename or delete one.
     */
    entryMenus?: boolean;
    /**
     * Flushes the pending edit of the split holding `href` before a
     * rename/delete mutate call fires (see route + before-mutate.ts). Wired
     * to EVERY row's EntryMenu, not just the open one, and it takes the
     * row's href: with two editable splits there is no "the one open page"
     * to flush — the caller has to be told WHICH file is about to be
     * mutated so it can flush the split that holds it and leave its sibling
     * alone. Rows holding nothing unsaved resolve to a no-op.
     */
    onBeforeMutate?: (href: string) => Promise<void>;
    /**
     * A row's Delete succeeded, naming the entry that went. Both dialogs
     * follow a mutation by rewriting every surface showing it — the route
     * pathname, `?split=`, and each `?pane=files:…` — directly in the URL
     * (`follow-mutation.ts`), which means a host holding per-split state has
     * no other way to learn that its list was renumbered under it. The Files
     * pane uses it to re-map the assistant's auto-open claim.
     *
     * A delete only: a rename maps paths in place and renumbers nothing. The
     * folder flag travels because a folder carries its descendants, and a host
     * has to decide for itself which of its own paths that covers.
     */
    onDeleted?: (target: { path: string; isFolder: boolean }) => void;
    /**
     * Selection mode (side-panes pass): when set, leaf rows call this
     * instead of navigating (pickers, and any host whose click means
     * "rewrite my descriptor" rather than "navigate the app"). Folder
     * expand/collapse behaves identically in both modes.
     */
    onSelect?: (sel: { mountKey: string; path: string }) => void;
    /**
     * "Open in a new tab" — a leaf row's hover-revealed affordance. Only leaf
     * rows offer it: a folder click expands the folder and never opens
     * anything, so there is nothing to put in a tab.
     *
     * It used to be "Open beside", a second split. Splits are gone; a plain
     * row click now replaces the tab you are reading, and this is how you keep
     * it and open another.
     */
    onOpenInTab?: (sel: { mountKey: string; path: string }) => void;
    /**
     * Why "Open in a new tab" cannot act, or null when it can. The tree has no
     * idea how many tabs its host has open, so the host computes this and
     * hands it down. Width is no longer ever the reason — a tab takes none.
     *
     * When set, the control still RENDERS — disabled, carrying this string as
     * its tooltip. A disabled control with a reason teaches; a missing one
     * just leaves the user wondering where it went. Same rule the spec sets
     * for the shell's own `＋ Pane`.
     */
    openInTabDisabled?: string | null;
  } = $props();

  const showMenus = $derived(entryMenus ?? onSelect === undefined);

  // The leaf row's right gutter holds 0, 1 or 2 size-8 controls; its padding
  // has to clear them or a long filename runs underneath.
  const gutterControls = $derived((onOpenInTab ? 1 : 0) + (showMenus ? 1 : 0));
  const leafPad = $derived(
    gutterControls === 0 ? 'pr-2' : gutterControls === 1 ? 'pr-9' : 'pr-[68px]'
  );

  function isActive(href: string): boolean {
    return activePaths.includes(href);
  }

  /**
   * The row on screen right now. Hosts that pass no `currentPath` keep the
   * behaviour they had — every open row reads as current — so the popover
   * pickers and the route's own tree are untouched.
   */
  function isCurrent(href: string): boolean {
    return currentPath === null ? isActive(href) : currentPath === href;
  }

  /**
   * Two levels of "open", without reaching for colour: the tab being read
   * carries the tree's active background, the other open tabs carry ink weight
   * alone. Being open is not a consequence, so nothing here is accented.
   */
  function rowTone(href: string): string {
    if (isCurrent(href)) return 'bg-paper-tree-active text-ink-heading';
    if (isActive(href)) return 'text-ink-heading';
    return 'text-ink-secondary';
  }

  /**
   * Binds this row's href into the flush hook. Captured into a local first so
   * the closure keeps a non-optional reference — the prop itself is a
   * reassignable binding, which TypeScript will not narrow across a callback.
   */
  function beforeMutateFor(href: string): (() => Promise<void>) | undefined {
    const flush = onBeforeMutate;
    return flush ? () => flush(href) : undefined;
  }

  /** Binds this row's own subject into the delete hook. Same capture reason as above. */
  function deletedFor(path: string, isFolder: boolean): (() => void) | undefined {
    const notify = onDeleted;
    return notify ? () => notify({ path, isFolder }) : undefined;
  }

  // Folders default CLOSED (file-browser performance pass): the lazy tree
  // only fetches a folder's listing when it's opened. Expansion state lives
  // in the shared, localStorage-persisted `treeOpenState` (keyed by href),
  // so the folders someone works in stay open across routes and reloads.
  function toggle(item: NavTreeItem) {
    treeOpenState.toggle(item.href);
    if (treeOpenState.isOpen(item.href) && item.loaded === false) {
      void icmStore.loadDir(item.mountKey, item.path);
    }
  }

  // Self-healing loader: a row can be open without a click ever having
  // fired `loadDir` for it — persisted expansion restored on a fresh
  // session, or a refetch that dropped a stale loaded-mark (see
  // `IcmStore.refetch`'s reconcile step). Whenever an open folder shows an
  // unloaded placeholder, fetch it; `loadDir` de-dupes, so this is a no-op
  // in the steady state.
  $effect(() => {
    for (const node of nodes) {
      if (node.children && node.loaded === false && treeOpenState.isOpen(node.href)) {
        void icmStore.loadDir(node.mountKey, node.path);
      }
    }
  });
</script>

<ul class="flex flex-col gap-0.5">
  {#each nodes as node (node.href)}
    <li>
      {#if node.children}
        <div class="group relative">
          <button
            type="button"
            onclick={() => toggle(node)}
            aria-current={isCurrent(node.href) ? 'page' : undefined}
            aria-expanded={treeOpenState.isOpen(node.href)}
            class={[
              'flex w-full items-center gap-1 rounded-md py-[3px] pr-9 pl-2 text-left text-[12.5px] transition-colors hover:bg-paper-pill',
              rowTone(node.href)
            ]}
          >
            <ChevronRight
              class={[
                'size-3 shrink-0 text-ink-meta transition-transform',
                treeOpenState.isOpen(node.href) ? 'rotate-90' : ''
              ]}
              strokeWidth={1.5}
            />
            <span class="flex-1 truncate">{node.label}</span>
            {#if node.count !== undefined}
              <span class="text-ink-meta text-[11px] tabular-nums">{node.count}</span>
            {/if}
          </button>
          {#if showMenus}
            <EntryMenu
              mountKey={node.mountKey}
              path={node.path}
              name={node.label}
              kind="folder"
              class="absolute top-1/2 right-0.5 -translate-y-1/2"
              onBeforeMutate={beforeMutateFor(node.href)}
              onDeleted={deletedFor(node.path, true)}
            />
          {/if}
        </div>
        {#if treeOpenState.isOpen(node.href)}
          <div class="ml-[17px] border-l border-paper-chip-border pl-2">
            {#if node.loaded === false}
              <p class="text-ink-meta px-2 py-[3px] text-[12px]">Loading…</p>
            {:else if node.children.length}
              <IcmTree
                nodes={node.children}
                {activePaths}
                {currentPath}
                {linkSearch}
                {entryMenus}
                {onBeforeMutate}
                {onDeleted}
                {onSelect}
                {onOpenInTab}
                {openInTabDisabled}
              />
            {:else}
              <p class="text-ink-meta px-2 py-[3px] text-[12px] italic">Empty</p>
            {/if}
          </div>
        {/if}
      {:else}
        <!-- `data-tree-href` rides on BOTH leaf forms, not just the anchor:
             a host that reveals a file scrolls to it by this attribute, and
             the Files pane — the one host that does — is in selection mode,
             so the button carries it or the reveal silently finds nothing. -->
        <div class="group relative">
          {#if onSelect}
            <button
              type="button"
              data-tree-href={node.href}
              onclick={() => onSelect?.({ mountKey: node.mountKey, path: node.path })}
              aria-current={isCurrent(node.href) ? 'page' : undefined}
              class={[
                'flex w-full items-center gap-1 rounded-md py-[3px] pl-2 text-left text-[12.5px] transition-colors hover:bg-paper-pill',
                leafPad,
                rowTone(node.href)
              ]}
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.isFile}
                <!-- Format badge for a non-.md file leaf — the same
                     `fileLeafLabel` text the separate (now removed)
                     non-clickable file rows showed ("FILE" when the file has
                     no extension at all). -->
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">
                  {fileLeafLabel(node.ext)}
                </span>
              {/if}
            </button>
          {:else}
            <a
              href={node.href + linkSearch}
              data-tree-href={node.href}
              aria-current={isCurrent(node.href) ? 'page' : undefined}
              class={[
                'flex items-center gap-1 rounded-md py-[3px] pl-2 text-[12.5px] transition-colors hover:bg-paper-pill',
                leafPad,
                rowTone(node.href)
              ]}
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.isFile}
                <!-- Format badge for a non-.md file leaf — the same
                     `fileLeafLabel` text the separate (now removed)
                     non-clickable file rows showed ("FILE" when the file has
                     no extension at all). -->
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">
                  {fileLeafLabel(node.ext)}
                </span>
              {/if}
            </a>
          {/if}
          <!-- The row's right gutter. Siblings of the row control, never
               nested inside it: an interactive control inside an <a> is
               invalid HTML and swallows the row's own click target. -->
          {#if gutterControls > 0}
            <div class="absolute top-1/2 right-0.5 flex -translate-y-1/2 items-center">
              {#if onOpenInTab}
                <!-- `aria-disabled`, not the `disabled` attribute: a truly
                     disabled button takes no pointer events, so its `title`
                     never appears — which would turn "disabled with the reason
                     on hover" back into the silent no-op this exists to
                     replace. Keyboard users can still focus it and hear the
                     reason, which is strictly better. -->
                <button
                  type="button"
                  title={openInTabDisabled ?? 'Open in a new tab'}
                  aria-label={`Open ${node.label} in a new tab`}
                  aria-disabled={openInTabDisabled ? 'true' : undefined}
                  onclick={(event) => {
                    event.stopPropagation();
                    if (openInTabDisabled) return;
                    onOpenInTab?.({ mountKey: node.mountKey, path: node.path });
                  }}
                  class={[
                    'text-ink-meta flex size-8 shrink-0 items-center justify-center rounded-md opacity-0 transition-colors group-hover:opacity-100 group-focus-within:opacity-100 focus-visible:opacity-100',
                    openInTabDisabled ? 'cursor-default' : 'hover:bg-paper-card hover:text-ink-heading'
                  ]}
                >
                  <!-- The unavailable state dims the ICON, never the button:
                       the button's opacity is the row's hover reveal, and a
                       second `group-hover:opacity-*` on the same element would
                       be a same-specificity fight decided by stylesheet order.
                       Nothing here reaches for accent colour — the strip being
                       full is not a consequence, it is a fact. -->
                  <SquarePlus
                    class={['size-3.5', openInTabDisabled ? 'opacity-40' : '']}
                    strokeWidth={1.5}
                  />
                </button>
              {/if}
              {#if showMenus}
                <!-- Both leaf kinds get the menu (Task 10): the backend rename
                     now preserves a non-.md file's own extension instead of
                     coercing `.md`, and delete never had a `.md` assumption to
                     begin with. `isFile` — never `ext` — is the file/page test:
                     an extension-less file (LICENSE, Makefile) has `ext: ''`.
                     `node.label` is what the dialogs pre-fill, and it is
                     already kind-correct (the backend's tree sends a file's
                     FULL basename, a page's title without `.md`). -->
                <EntryMenu
                  mountKey={node.mountKey}
                  path={node.path}
                  name={node.label}
                  kind={node.isFile ? 'file' : 'page'}
                  onBeforeMutate={beforeMutateFor(node.href)}
                  onDeleted={deletedFor(node.path, false)}
                />
              {/if}
            </div>
          {/if}
        </div>
      {/if}
    </li>
  {/each}
</ul>
