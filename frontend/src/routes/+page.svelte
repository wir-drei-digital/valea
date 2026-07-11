<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { icmToNav } from '$lib/shell/nav';
  import { normalizeCockpitToday, splitTrustClause, mailSummaryLine, type CockpitToday } from '$lib/today/cockpit';
  import { fromLabel, subjectLabel } from '$lib/components/mail/mail-shapes';
  import PreparedItemCard from '$lib/components/today/PreparedItemCard.svelte';
  import InquiryTriageCard from '$lib/components/today/InquiryTriageCard.svelte';
  import ScheduleList from '$lib/components/today/ScheduleList.svelte';
  import OpenLoops from '$lib/components/today/OpenLoops.svelte';
  import AwayList from '$lib/components/today/AwayList.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  // The seeded cockpit narrative's Priya Nair entry — Task 18 stopped
  // rendering it (and its rich seed copy) inline via `InquiryTriageCard
  // {item}`; that card is now generalized (`{path, fromName, subject}`
  // props) and rendered separately below, either once with defaults (not
  // configured) or once per real review message (configured). This title
  // is only used to filter that ONE entry back out of the generic
  // `PreparedItemCard` loop so it doesn't render twice.
  const SEED_INQUIRY_TITLE = 'Priya Nair · new inquiry';

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
    // Populates `mailStore.messages` so a configured workspace's Today page
    // can render one `InquiryTriageCard` per review message. Live updates
    // arrive via the same shared join's mail pushes (`wireMailEvents`,
    // wired once from `wireIcmEvents`) — same "refetch once on mount, pushes
    // keep it fresh" convention `/mail`'s own `onMount` uses.
    void mailStore.refreshMessages();
  });

  const icmNav = $derived(icmToNav(icmStore.nodes));
  const trust = $derived.by(() => splitTrustClause(today?.summary ?? ''));

  const otherPreparedItems = $derived.by(() =>
    (today?.preparedItems ?? []).filter((item) => item.title !== SEED_INQUIRY_TITLE)
  );

  // Only messages with an indexed path can actually be run through the
  // triage workflow (`api.runWorkflow` needs a real `input` path) — a
  // defensive filter, not an expected case (`Store.list_messages/0` always
  // carries the file's own path).
  const reviewMessages = $derived(
    mailStore.messages.filter((m): m is typeof m & { path: string } => m.status === 'review' && !!m.path)
  );

  const preparedCount = $derived.by(() => {
    if (!today) return 0;
    return otherPreparedItems.length + (today.mail.configured ? reviewMessages.length : 1);
  });
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
          {#if today.mail.configured}
            <span class="text-ink-meta">· {mailSummaryLine(today.mail)}</span>
          {/if}
        </p>
      </header>

      <div class="mt-8 grid grid-cols-1 gap-x-8 gap-y-10 min-[900px]:grid-cols-[2fr_3fr]">
        <section>
          <p class="text-overline mb-2">Today's schedule</p>
          <ScheduleList items={today.schedule} />
        </section>

        <section>
          <p class="text-overline mb-3">Prepared for you · {preparedCount}</p>
          <div class="flex flex-col gap-4">
            {#if today.mail.configured}
              {#each reviewMessages as message (message.msgId)}
                <InquiryTriageCard
                  path={message.path}
                  fromName={fromLabel(message)}
                  subject={subjectLabel(message.subject)}
                />
              {/each}
            {:else}
              <InquiryTriageCard />
            {/if}
            {#each otherPreparedItems as item (item.title)}
              <PreparedItemCard {item} />
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
