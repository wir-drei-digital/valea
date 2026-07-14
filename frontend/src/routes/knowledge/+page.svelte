<script lang="ts">
  // Knowledge index (A-T15: mounts-aware). With exactly one enabled mount
  // this looks EXACTLY like the pre-mounts page: top-level folders in a
  // flat list, one "New" action in the pane header. With two or more
  // enabled mounts, the tree splits into one section per mount (title +
  // description header, its own "New" action targeting THAT mount's own
  // root) — see `buildMountsDisplay` in `mount-sections.ts` for the
  // collapse decision. A collapsed "Deactivated" group at the bottom lists
  // every disabled, non-degraded mount with a re-enable toggle; a degraded
  // mount (manifest missing/invalid, regardless of its enabled flag) shows
  // as a non-clickable warning chip instead — see `classifyMounts`.
  import { onMount } from 'svelte';
  import { AppFrame, ListPane, PageHeader, SectionOverline } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { encodePath, type IcmNode } from '$lib/shell/nav';
  import {
    adoptFailureBannerText,
    buildMountsDisplay,
    classifyMounts,
    degradedChipLabel,
    isExternalRootRel,
    isExternalMount
  } from '$lib/components/knowledge/mount-sections';
  import { fileLeafKind, fileLeafLabel } from '$lib/components/knowledge/file-leaf';
  import NewEntryDialog from '$lib/components/knowledge/NewEntryDialog.svelte';
  import NewEntryButton from '$lib/components/knowledge/NewEntryButton.svelte';
  import EntryMenu from '$lib/components/knowledge/EntryMenu.svelte';
  import MountFromElsewhereDialog from '$lib/components/knowledge/MountFromElsewhereDialog.svelte';
  import MountsDoctorPanel from '$lib/components/knowledge/MountsDoctorPanel.svelte';
  import UnmountDialog from '$lib/components/knowledge/UnmountDialog.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';
  import TriangleAlert from '@lucide/svelte/icons/triangle-alert';
  import ImageIcon from '@lucide/svelte/icons/image';
  import FileText from '@lucide/svelte/icons/file-text';
  import FileIcon from '@lucide/svelte/icons/file';

  onMount(() => {
    // `icmStore.refetch()` is already kicked off by `AppFrame`'s own
    // `onMount` (wired once, shared across every route) — `mountsStore`,
    // by contrast, has no consumer before this page, so nothing else
    // refreshes it. Kept live afterwards by the same `mounts_changed` push
    // `wireMountsEvents` already subscribes on the shared
    // `workspace:events` join (see `mounts.svelte.ts`).
    void mountsStore.refresh();
  });

  const display = $derived(buildMountsDisplay(icmStore.groups, mountsStore.mounts));
  const classification = $derived(classifyMounts(mountsStore.mounts));

  function folders(tree: IcmNode[]): IcmNode[] {
    return tree.filter((n) => n.type === 'folder');
  }

  // A-T15 fix wave: non-.md file leaves (media/PDF) at a mount's top level.
  // Rendered as non-clickable rows below the folders — visible ("reveal"),
  // but never navigable: only .md pages open in the editor.
  function fileLeaves(tree: IcmNode[]): IcmNode[] {
    return tree.filter((n) => n.type === 'file');
  }

  let newEntryMode: 'page' | 'folder' = $state('page');
  let newEntryOpen = $state(false);
  let newEntryParent = $state('');

  // `parentRoot` is the mount's own workspace-relative root (`rootRel`,
  // e.g. `"mounts/primary"`) — NOT `""`. A page/folder create RPC resolves
  // its owning mount from the parent path alone (`Valea.Mounts.mount_for/1`
  // — see `Valea.ICM`'s moduledoc), and `""` doesn't name any mount, so an
  // empty parentRoot would 404 as `outside_workspace`. When there is
  // nowhere to create into (zero enabled mounts), `openNew` is simply never
  // wired to a control — see the collapsed-with-no-rootRel guard below.
  function openNew(parentRoot: string, mode: 'page' | 'folder') {
    newEntryParent = parentRoot;
    newEntryMode = mode;
    newEntryOpen = true;
  }

  let deactivatedOpen = $state(false);
  let reenabling: Record<string, boolean> = $state({});
  let reenableError: Record<string, string> = $state({});

  // `mountKey` (task 3.4) — `MountSummary.name` is now the ICM's DISPLAY
  // name, not its stable `icms:` config key, so every call that mutates a
  // mount must address it by `mountKey`, not `name`.
  async function reenable(mountKey: string): Promise<void> {
    reenabling = { ...reenabling, [mountKey]: true };
    reenableError = { ...reenableError, [mountKey]: '' };
    const result = await mountsStore.setEnabled(mountKey, true, workspaceStore.generation ?? 0);
    reenabling = { ...reenabling, [mountKey]: false };
    if (!result.ok) {
      reenableError = { ...reenableError, [mountKey]: result.error };
    }
  }

  // A2-T9: "Mount a folder from elsewhere…" and the mounts doctor — both
  // pinned-footer affordances (`ListPane`'s `footer` snippet), same
  // placement pattern the panel-per-feature-route precedent already sets
  // (`agent/DoctorPanel` inline in `/chat`, `mail/MailDoctorPanel` inline in
  // `/mail`'s `SetupPanel`): the mounts doctor is a mounts-shaped concern,
  // so it lives right here in mounts' own route rather than a separate
  // settings page (this app has none).
  let mountFromElsewhereOpen = $state(false);
  let doctorOpen = $state(false);

  // "Unmount" (A2-T9) — one dialog instance for every external-mount row
  // across the active sections, degraded chips, and deactivated list (same
  // per-row-props pattern `DeleteDialog`/`RenameDialog` use via `EntryMenu`).
  let unmountTarget = $state('');
  let unmountOpen = $state(false);

  // `mountKey` (task 3.4) — see `reenable`'s comment above.
  function openUnmount(mountKey: string): void {
    unmountTarget = mountKey;
    unmountOpen = true;
  }
</script>

{#snippet folderRow(folder: IcmNode)}
  <li class="group relative">
    <a
      href={`/knowledge/${encodePath(folder.path)}`}
      class="text-ink-body hover:bg-paper-pill flex items-center gap-2 border-l-[3px] border-transparent py-2 pr-9 pl-3 text-[13px] transition-colors"
    >
      <span class="min-w-0 flex-1 truncate">{folder.name}</span>
      <span class="text-ink-meta text-[11px] tabular-nums">{folder.pageCount ?? 0}</span>
    </a>
    <EntryMenu
      path={folder.path}
      name={folder.name}
      isFolder={true}
      class="absolute top-1/2 right-0.5 -translate-y-1/2"
    />
  </li>
{/snippet}

{#snippet fileRow(file: IcmNode)}
  <!-- Non-clickable by design: only .md pages open in the editor. -->
  <li class="text-ink-secondary flex items-center gap-2 border-l-[3px] border-transparent py-2 pr-3 pl-3 text-[13px]">
    {#if fileLeafKind(file.ext) === 'image'}
      <ImageIcon class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
    {:else if fileLeafKind(file.ext) === 'pdf'}
      <FileText class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
    {:else}
      <FileIcon class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
    {/if}
    <span class="min-w-0 flex-1 truncate">{file.name}</span>
    <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em]">{fileLeafLabel(file.ext)}</span>
  </li>
{/snippet}

<AppFrame>
  {#snippet list()}
    <ListPane title="Knowledge">
      {#snippet action()}
        {#if display.collapsed && display.rootRel}
          <NewEntryButton onNew={(mode) => openNew(display.rootRel, mode)} />
        {/if}
      {/snippet}
      {#snippet children()}
        {#if display.collapsed}
          <ul class="flex flex-col py-1">
            {#each folders(display.tree) as folder (folder.path)}
              {@render folderRow(folder)}
            {/each}
            {#each fileLeaves(display.tree) as file (file.path)}
              {@render fileRow(file)}
            {/each}
          </ul>
        {:else}
          {#each display.sections as section (section.mount)}
            <div>
              <div class="flex items-start justify-between gap-2 px-2 pt-4 pb-1">
                <div class="min-w-0">
                  <p class="text-overline">{section.title}</p>
                  {#if section.description}
                    <p class="text-ink-meta mt-0.5 truncate text-[11.5px]">{section.description}</p>
                  {/if}
                  {#if isExternalRootRel(section.rootRel)}
                    <!-- A2-T5b: an external (by-reference) mount's content lives
                         outside the workspace — show WHERE, since that's not
                         otherwise implied the way an embedded mount's is. -->
                    <p class="text-ink-meta mt-0.5 truncate font-mono text-[10.5px]" title={section.rootRel}>
                      {section.rootRel}
                    </p>
                    <button
                      type="button"
                      onclick={() => openUnmount(section.mount)}
                      class="text-ink-meta hover:text-warn-ink mt-0.5 text-[11px] underline-offset-2 hover:underline"
                    >
                      Unmount
                    </button>
                  {/if}
                </div>
                <NewEntryButton onNew={(mode) => openNew(section.rootRel, mode)} />
              </div>
              <ul class="flex flex-col py-1">
                {#each folders(section.tree) as folder (folder.path)}
                  {@render folderRow(folder)}
                {/each}
                {#each fileLeaves(section.tree) as file (file.path)}
                  {@render fileRow(file)}
                {/each}
              </ul>
            </div>
          {/each}
        {/if}

        {#if classification.degraded.length > 0}
          <div>
            <SectionOverline label="Needs attention" />
            <ul class="flex flex-col gap-1.5 px-2 pb-3">
              {#each classification.degraded as mount (mount.mountKey)}
                <li
                  class="bg-warn-tint text-warn-ink flex items-start gap-2 rounded-md px-2.5 py-2 text-[12px]"
                  title={degradedChipLabel(mount)}
                >
                  <TriangleAlert class="mt-0.5 size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
                  <span class="min-w-0 flex-1">
                    <span class="block truncate font-semibold">{mount.name}</span>
                    <span class="block text-[11px] opacity-90">{degradedChipLabel(mount)}</span>
                    {#if isExternalMount(mount)}
                      <span class="mt-0.5 block truncate font-mono text-[10.5px] opacity-80" title={mount.root}>
                        {mount.root}
                      </span>
                      <button
                        type="button"
                        onclick={() => openUnmount(mount.mountKey)}
                        class="mt-0.5 text-[11px] underline-offset-2 hover:underline"
                      >
                        Unmount
                      </button>
                    {/if}
                  </span>
                </li>
              {/each}
            </ul>
          </div>
        {/if}

        {#if classification.deactivated.length > 0}
          <div>
            <button
              type="button"
              onclick={() => (deactivatedOpen = !deactivatedOpen)}
              class="text-ink-secondary hover:bg-paper-pill flex w-full items-center gap-1 rounded-md px-2 py-2 text-left text-[12.5px] transition-colors"
            >
              <ChevronRight
                class={['size-3 shrink-0 transition-transform', deactivatedOpen ? 'rotate-90' : '']}
                strokeWidth={1.5}
              />
              <span class="flex-1">Deactivated</span>
              <span class="text-ink-meta text-[11px] tabular-nums">{classification.deactivated.length}</span>
            </button>
            {#if deactivatedOpen}
              <ul class="flex flex-col gap-1 px-2 pb-3">
                {#each classification.deactivated as mount (mount.mountKey)}
                  <!-- The error line lives INSIDE the <li> — a <p> as a direct
                       child of <ul> is invalid markup. -->
                  <li class="flex flex-col gap-1 py-1">
                    <div class="flex items-center justify-between gap-2">
                      <span class="min-w-0 flex-1">
                        <span class="text-ink-secondary block truncate text-[13px]">{mount.name}</span>
                        {#if isExternalMount(mount)}
                          <span class="text-ink-meta block truncate font-mono text-[10.5px]" title={mount.root}>
                            {mount.root}
                          </span>
                        {/if}
                      </span>
                      <div class="flex shrink-0 items-center gap-1.5">
                        {#if isExternalMount(mount)}
                          <Button type="button" variant="outline" size="sm" onclick={() => openUnmount(mount.mountKey)}>
                            Unmount
                          </Button>
                        {/if}
                        <Button
                          type="button"
                          variant="outline"
                          size="sm"
                          disabled={!!reenabling[mount.mountKey]}
                          onclick={() => void reenable(mount.mountKey)}
                        >
                          {reenabling[mount.mountKey] ? 'Enabling…' : 'Enable'}
                        </Button>
                      </div>
                    </div>
                    {#if reenableError[mount.mountKey]}
                      <p class="text-warn-ink text-[11px]" role="alert">{reenableError[mount.mountKey]}</p>
                    {/if}
                  </li>
                {/each}
              </ul>
            {/if}
          </div>
        {/if}
      {/snippet}

      {#snippet footer()}
        <div class="flex items-center justify-between gap-2">
          <button
            type="button"
            onclick={() => (mountFromElsewhereOpen = true)}
            class="text-ink-secondary hover:text-ink-heading text-[12px]"
          >
            Mount a folder from elsewhere…
          </button>
          <button
            type="button"
            onclick={() => (doctorOpen = true)}
            class="text-ink-meta hover:text-ink-heading text-[12px]"
          >
            Check your mounts
          </button>
        </div>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    <!-- Fix wave 1 (A2-T9): a declare-stage reference-adoption failure
         outlives the onboarding screen (see PendingAdoptError's doc comment
         in stores/mounts.svelte.ts) — surfaced HERE, the first mounts-shaped
         surface a fresh workspace lands on, as a prominent dismissible
         banner. Rendered above BOTH main-pane states (header and doctor)
         so toggling the doctor can't hide it. -->
    {#if mountsStore.pendingAdoptError}
      <div
        role="alert"
        class="bg-warn-tint text-warn-ink mb-4 flex items-start gap-2.5 rounded-lg px-4 py-3"
      >
        <TriangleAlert class="mt-0.5 size-4 shrink-0" strokeWidth={1.5} aria-hidden="true" />
        <p class="min-w-0 flex-1 text-[13px] leading-relaxed">
          {adoptFailureBannerText(mountsStore.pendingAdoptError)}
        </p>
        <Button
          type="button"
          variant="outline"
          size="sm"
          class="shrink-0"
          onclick={() => mountsStore.clearPendingAdoptError()}
        >
          Dismiss
        </Button>
      </div>
    {/if}

    {#if doctorOpen}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
        <button
          type="button"
          onclick={() => (doctorOpen = false)}
          class="text-ink-secondary hover:text-ink-heading mb-2 flex items-center gap-1 text-[12.5px]"
        >
          <ChevronLeft class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
          Back to Knowledge
        </button>
        <MountsDoctorPanel generation={workspaceStore.generation ?? 0} />
      </div>
    {:else}
      <PageHeader
        title="Knowledge"
        subtitle="Your business memory — every page is a plain Markdown file in your workspace."
      />
    {/if}
  {/snippet}
</AppFrame>

<NewEntryDialog mode={newEntryMode} parentPath={newEntryParent} bind:open={newEntryOpen} />
<MountFromElsewhereDialog bind:open={mountFromElsewhereOpen} />
<UnmountDialog name={unmountTarget} bind:open={unmountOpen} />
