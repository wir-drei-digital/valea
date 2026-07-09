<script lang="ts">
  import { page } from '$app/state';
  import { mainNav, type NavTreeItem } from '$lib/shell/nav';
  import SidebarItem from './SidebarItem.svelte';
  import SectionOverline from './SectionOverline.svelte';
  import IcmTree from './IcmTree.svelte';
  import StatusPill from './StatusPill.svelte';
  import * as Tooltip from '$lib/components/ui/tooltip/index.js';

  let {
    workspaceName,
    icmNav,
    syncedAt
  }: {
    workspaceName: string;
    icmNav: NavTreeItem[];
    syncedAt?: string;
  } = $props();

  const sections = mainNav();
  const initials = $derived(
    workspaceName
      .split(' ')
      .filter(Boolean)
      .slice(0, 2)
      .map((w) => w[0]?.toUpperCase())
      .join('')
  );
</script>

<div class="flex h-full flex-col">
  <div class="flex items-center gap-2.5 px-3 pt-4 pb-3">
    <div
      class="flex size-8 shrink-0 items-center justify-center rounded-full bg-paper-nav-active text-[12px] font-semibold text-ink-heading"
    >
      {initials}
    </div>
    <div class="min-w-0">
      <p class="truncate text-[13.5px] font-semibold text-ink-heading">{workspaceName}</p>
      <p class="text-ink-meta text-[11px]">Local workspace</p>
    </div>
  </div>

  <nav class="flex-1 overflow-y-auto px-2 pb-2">
    {#each sections as section (section.label ?? 'daily')}
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
          {#if item.id === 'knowledge'}
            <div class="mt-0.5 mb-1 ml-[17px] border-l border-paper-chip-border pl-2">
              <IcmTree nodes={icmNav} activePath={page.url.pathname} />
            </div>
          {/if}
        {/each}
      </div>
    {/each}
  </nav>

  <footer class="mt-auto flex flex-col gap-2 px-3 pb-3">
    <StatusPill label={syncedAt ? `All local · synced ${syncedAt}` : 'All local'} />
    <Tooltip.Provider>
      <Tooltip.Root>
        <!-- Wrapper span carries the trigger + hover, since a disabled <button> swallows pointer events. -->
        <Tooltip.Trigger class="inline-block w-fit cursor-not-allowed">
          <span
            class="font-mono text-ink-meta hover:text-ink-secondary pointer-events-none block px-2 py-2 text-left text-[11.5px]"
          >
            &gt;_ Open the hood
          </span>
        </Tooltip.Trigger>
        <Tooltip.Content>Coming with the audit log</Tooltip.Content>
      </Tooltip.Root>
    </Tooltip.Provider>
  </footer>
</div>
