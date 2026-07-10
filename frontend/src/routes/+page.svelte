<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { icmToNav } from '$lib/shell/nav';
  import { normalizeCockpitToday, splitTrustClause, type CockpitToday } from '$lib/today/cockpit';
  import PreparedItemCard from '$lib/components/today/PreparedItemCard.svelte';
  import InquiryTriageCard from '$lib/components/today/InquiryTriageCard.svelte';
  import ScheduleList from '$lib/components/today/ScheduleList.svelte';
  import OpenLoops from '$lib/components/today/OpenLoops.svelte';
  import AwayList from '$lib/components/today/AwayList.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  let today: CockpitToday | null = $state(null);
  let failed = $state(false);
  let loading = $state(true);

  async function load() {
    loading = true;
    failed = false;
    const result = await api.cockpitToday();
    if (result.ok) {
      today = normalizeCockpitToday(result.data as Record<string, any>);
    } else {
      failed = true;
    }
    loading = false;
  }

  onMount(() => {
    void load();
    // First render of the shared sidebar — populate the ICM tree once here;
    // live refetch wiring (workspace:events) lands with Task 18.
    void icmStore.refetch();
    // Populates queueStore.items on first load so a reload after a previous
    // "Prepare a reply" run picks the InquiryTriageCard straight into its
    // approval-card state instead of flashing the seeded idle card first.
    // Live updates after this are pushed via `queue_changed` (wired at the
    // shared `workspace:events` join — see `wireIcmEvents` in `icm.svelte.ts`).
    void queueStore.refetch();
  });

  const icmNav = $derived(icmToNav(icmStore.nodes));
  const trust = $derived.by(() => splitTrustClause(today?.summary ?? ''));
</script>

<AppShell>
  {#snippet sidebar()}
    <Sidebar workspaceName={workspaceStore.name ?? 'Workspace'} {icmNav} />
  {/snippet}

  {#snippet main()}
    {#if loading}
      <div class="flex flex-col gap-6" aria-hidden="true">
        <div class="flex flex-col gap-3">
          <Skeleton class="h-3 w-44" />
          <Skeleton class="h-9 w-72" />
          <Skeleton class="h-4 w-full max-w-[520px]" />
        </div>
        <div class="grid grid-cols-1 gap-8 min-[900px]:grid-cols-[2fr_3fr]">
          <div class="flex flex-col gap-3">
            <Skeleton class="h-3 w-32" />
            <Skeleton class="h-40 w-full" />
          </div>
          <div class="flex flex-col gap-3">
            <Skeleton class="h-3 w-36" />
            <Skeleton class="h-44 w-full rounded-xl" />
            <Skeleton class="h-44 w-full rounded-xl" />
          </div>
        </div>
      </div>
    {:else if failed || !today}
      <div class="flex flex-col items-start gap-3 py-10">
        <p class="text-ink-body text-[13.5px]">
          Couldn't load your day. The backend may still be starting.
        </p>
        <Button variant="outline" size="sm" onclick={() => void load()}>Retry</Button>
      </div>
    {:else}
      <header class="flex flex-col gap-2">
        <p class="text-overline">{today.dateLabel}</p>
        <h1 class="font-display text-ink-heading text-[36px] leading-tight font-medium">
          {today.greeting}
        </h1>
        <p class="text-ink-body max-w-[560px] text-[14px]">
          {trust.lead}<strong class="text-ink-heading">{trust.trust}</strong>
        </p>
      </header>

      <div class="mt-8 grid grid-cols-1 gap-x-8 gap-y-10 min-[900px]:grid-cols-[2fr_3fr]">
        <section>
          <p class="text-overline mb-2">Today's schedule</p>
          <ScheduleList items={today.schedule} />
        </section>

        <section>
          <p class="text-overline mb-3">Prepared for you · {today.preparedItems.length}</p>
          <div class="flex flex-col gap-4">
            {#each today.preparedItems as item (item.title)}
              {#if item.title === 'Priya Nair · new inquiry'}
                <InquiryTriageCard {item} />
              {:else}
                <PreparedItemCard {item} />
              {/if}
            {/each}
          </div>
        </section>
      </div>

      <section class="mt-10">
        <p class="text-overline mb-2">Open loops</p>
        <OpenLoops loops={today.openLoops} />
      </section>

      <section class="mt-10 pb-6">
        <p class="text-overline mb-3">While you were away</p>
        <AwayList items={today.whileYouWereAway} />
      </section>
    {/if}
  {/snippet}
</AppShell>
