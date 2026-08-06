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
  // The top of the nav answers to the window CHROME, not the runtime — hence
  // `windowChrome()` rather than `inDesktop()`. Two shapes, and macOS is the
  // one that differs.
  //
  // On macOS the traffic lights float over the webview at the window's
  // top-left, exactly where the brand lockup would sit. That platform gets an
  // EMPTY 48px band instead: clearance for the lights, and a drag surface.
  //
  // Everywhere else the lockup renders — the browser as it always has, and
  // frameless Windows and Linux, where nothing occupies that corner and the
  // band was dead space. (This reverses
  // `2026-08-02-frameless-windows-linux-chrome-design.md`'s "reused as-is; it
  // already renders on every desktop OS": the band's REASON is the traffic
  // lights, and only one of the three platforms has them.)
  //
  // DRAG. Both shapes are the app's LARGE drag surface, alongside the root
  // layout's 12px top strip — which is deliberately too thin to be the only
  // one. The attribute's VALUE is what makes the filled shape work: a bare
  // `data-tauri-drag-region` fires only when the mousedown lands on the
  // element carrying it, which across a lockup would mean the gap between the
  // mark and the wordmark and nothing else. `"deep"` extends it to the whole
  // subtree (tauri 2.11 `src/window/scripts/drag.js`), and nothing in ours
  // blocks it — the `<svg>` is an SVGElement, which that walk skips outright
  // rather than treating as a barrier, and the `<p>` is inert. The empty band
  // says `"deep"` too: with no children the two values are the same thing
  // there, and it stays correct if one ever lands.
  const chrome = windowChrome();

  let settingsOpen = $state(false);
</script>

<div class="flex h-full flex-col">
  <!-- Brand header. Chromeless on macOS ONLY — no mark, no wordmark, because
       the traffic lights live in that corner (the brand shows on the
       onboarding screen instead) — and the lockup everywhere else.

       `select-none` off the browser: the wordmark is a drag surface there, and
       while Tauri's own `preventDefault` already stops a drag selecting it,
       the I-beam cursor over what behaves as a title bar still reads wrong. -->
  {#if chrome === 'macos-overlay'}
    <div data-tauri-drag-region="deep" class="h-12 shrink-0"></div>
  {:else}
    <div
      data-tauri-drag-region={chrome === 'browser' ? undefined : 'deep'}
      class={['flex items-center gap-2.5 px-3 pt-4 pb-3', chrome !== 'browser' && 'select-none']}
    >
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
