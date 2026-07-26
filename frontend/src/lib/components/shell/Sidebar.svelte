<script lang="ts">
  import { page } from '$app/state';
  import Settings from '@lucide/svelte/icons/settings';
  import { mainNav } from '$lib/shell/nav';
  import { inDesktop } from '$lib/keychain';
  import Logo from './Logo.svelte';
  import SidebarItem from './SidebarItem.svelte';
  import SectionOverline from './SectionOverline.svelte';
  import IcmProjects from './IcmProjects.svelte';
  import MountIcmAction from './MountIcmAction.svelte';
  import StatusPill from './StatusPill.svelte';
  import UpdateNotice from './UpdateNotice.svelte';
  import WorkspaceSwitcher from './WorkspaceSwitcher.svelte';
  import HarnessSettingsModal from '$lib/components/agent/HarnessSettingsModal.svelte';

  let {
    activeMountKey = null,
    syncedAt,
    onBeforeMutateActive
  }: {
    /** Forwarded to `IcmProjects` — see its own doc comment for what this drives. */
    activeMountKey?: string | null;
    syncedAt?: string;
    /** Forwarded to `WorkspaceSwitcher` — see `workspaceStore.switchTo`'s doc comment. */
    onBeforeMutateActive?: () => Promise<void>;
  } = $props();

  const sections = mainNav();
  // Desktop (Tauri) runs with an overlay title bar: the macOS traffic
  // lights float over the webview at the window's top-left, exactly where
  // this sidebar's brand header sits. Clear them with extra top padding and
  // make the whole band a window-drag region (children are
  // pointer-events-none so a mousedown anywhere in the band targets the
  // band itself — Tauri's drag handler only fires on the element that
  // carries the attribute).
  const desktop = inDesktop();

  let settingsOpen = $state(false);
</script>

<div class="flex h-full flex-col">
  <!-- Brand header: the mark + wordmark. The ACTIVE WORKSPACE is the
       footer's WorkspaceSwitcher, not this header. -->
  <div
    data-tauri-drag-region
    class={['flex items-center gap-2.5 px-3 pb-3', desktop ? 'pt-12' : 'pt-4']}
  >
    <span class={['flex items-center gap-2.5', desktop && 'pointer-events-none select-none']}>
      <Logo />
      <p class="font-display text-ink-heading text-[17px] font-medium">Valea</p>
    </span>
  </div>

  <nav class="flex-1 overflow-y-auto px-2 pb-2">
    {#each sections as section, index (section.label ?? 'daily')}
      {#if section.label}
        <SectionOverline label={section.label} />
      {/if}
      <div class="flex flex-col gap-0.5">
        {#each section.items as item (item.id)}
          <SidebarItem
            label={item.label}
            href={item.href}
            icon={item.icon}
            active={page.url.pathname === item.href ||
              (item.href !== '/' && page.url.pathname.startsWith(item.href + '/'))}
            currentPage={page.url.pathname === item.href}
          />
        {/each}
      </div>

      {#if index === 0}
        <!-- Projects (the user's ICM folders) are the app's primary object —
             they sit directly under the daily group, above the workspace
             utilities. "Projects" over "ICMs": nav copy stays jargon-free. -->
        <SectionOverline label="Projects" />
        <IcmProjects {activeMountKey} />
        <MountIcmAction />
      {/if}
    {/each}
  </nav>

  <footer class="mt-auto flex flex-col gap-2 px-3 pb-3">
    <UpdateNotice />
    <div class="flex items-center gap-1">
      <div class="min-w-0 flex-1">
        <WorkspaceSwitcher {onBeforeMutateActive} />
      </div>
      <button
        type="button"
        aria-label="Agent settings"
        title="Agent settings"
        onclick={() => (settingsOpen = true)}
        class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill shrink-0 rounded-md p-1.5 transition-colors"
      >
        <Settings class="size-4" strokeWidth={1.5} />
      </button>
    </div>
    <StatusPill label={syncedAt ? `All local · synced ${syncedAt}` : 'All local'} />
  </footer>
</div>

<HarnessSettingsModal bind:open={settingsOpen} />
