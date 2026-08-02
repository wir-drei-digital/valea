<script lang="ts">
  import { page } from '$app/state';
  import Settings from '@lucide/svelte/icons/settings';
  import { mainNav } from '$lib/shell/nav';
  import { windowChrome } from '$lib/shell/platform';
  import Logo from './Logo.svelte';
  import SidebarItem from './SidebarItem.svelte';
  import SectionOverline from './SectionOverline.svelte';
  import IcmProjects from './IcmProjects.svelte';
  import MountIcmAction from './MountIcmAction.svelte';
  import StatusPill from './StatusPill.svelte';
  import UpdateNotice from './UpdateNotice.svelte';
  import WorkspaceSwitcher from './WorkspaceSwitcher.svelte';
  import SettingsModal from '$lib/components/settings/SettingsModal.svelte';

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
  // The brand band doubles as the traffic-light clearance on macOS and as a
  // drag surface everywhere the app owns its frame. `windowChrome()` rather
  // than `inDesktop()`: the two are the same set today, but the reason the
  // band exists is the chrome, not the runtime.
  //
  // On macOS the lights float over the webview at the window's top-left,
  // exactly where the brand lockup would sit — hence the empty 48px band,
  // which carries `data-tauri-drag-region` itself because Tauri's drag
  // handler only fires on the element the mousedown lands on.
  //
  // On frameless Windows and Linux there are no traffic lights to clear, but
  // the band stays: it is the app's LARGE drag surface, alongside the root
  // layout's 12px top strip — which is deliberately too thin to be the only
  // one. (It rendered there before those windows went frameless too, as dead
  // space beside a native title bar; what changed is that it now earns its
  // height.)
  const chrome = windowChrome();

  let settingsOpen = $state(false);
</script>

<div class="flex h-full flex-col">
  <!-- Brand header. In the DESKTOP app this band is chromeless — no mark, no
       wordmark (on macOS the traffic lights live here instead; the brand
       shows on the onboarding screen) — but it stays as that clearance and
       as a window-drag surface. In the browser it carries the lockup. -->
  {#if chrome !== 'browser'}
    <div data-tauri-drag-region class="h-12 shrink-0"></div>
  {:else}
    <div class="flex items-center gap-2.5 px-3 pt-4 pb-3">
      <Logo />
      <p class="font-display text-ink-heading text-[17px] font-medium">Valea</p>
    </div>
  {/if}

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
        aria-label="Settings"
        title="Settings"
        onclick={() => (settingsOpen = true)}
        class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill shrink-0 rounded-md p-1.5 transition-colors"
      >
        <Settings class="size-4" strokeWidth={1.5} />
      </button>
    </div>
    <StatusPill label={syncedAt ? `All local · synced ${syncedAt}` : 'All local'} />
  </footer>
</div>

<SettingsModal bind:open={settingsOpen} />
