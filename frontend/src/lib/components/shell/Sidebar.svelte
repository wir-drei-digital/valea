<script lang="ts">
  import { page } from '$app/state';
  import { mainNav } from '$lib/shell/nav';
  import Logo from './Logo.svelte';
  import SidebarItem from './SidebarItem.svelte';
  import SectionOverline from './SectionOverline.svelte';
  import IcmProjects from './IcmProjects.svelte';
  import MountIcmAction from './MountIcmAction.svelte';
  import StatusPill from './StatusPill.svelte';
  import UpdateNotice from './UpdateNotice.svelte';
  import WorkspaceSwitcher from './WorkspaceSwitcher.svelte';

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
</script>

<div class="flex h-full flex-col">
  <!-- Brand header: the mark + wordmark. The ACTIVE WORKSPACE is the
       footer's WorkspaceSwitcher, not this header. -->
  <div class="flex items-center gap-2.5 px-3 pt-4 pb-3">
    <Logo />
    <p class="font-display text-ink-heading text-[17px] font-medium">Valea</p>
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
    <WorkspaceSwitcher {onBeforeMutateActive} />
    <StatusPill label={syncedAt ? `All local · synced ${syncedAt}` : 'All local'} />
  </footer>
</div>
