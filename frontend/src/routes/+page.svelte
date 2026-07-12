<script lang="ts">
  import { onMount } from 'svelte';
  import { api } from '$lib/api/client';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { queueStore } from '$lib/stores/queue.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { icmToNav, flattenMountGroups } from '$lib/shell/nav';
  import { normalizeCockpitToday, splitTrustClause, mailSummaryLine, type CockpitToday } from '$lib/today/cockpit';
  import { fromLabel, subjectLabel } from '$lib/components/mail/mail-shapes';
  import { genericSummary } from '$lib/components/today/triage-card';
  import PreparedItemCard from '$lib/components/today/PreparedItemCard.svelte';
  import InquiryTriageCard from '$lib/components/today/InquiryTriageCard.svelte';
  import ScheduleList from '$lib/components/today/ScheduleList.svelte';
  import OpenLoops from '$lib/components/today/OpenLoops.svelte';
  import AwayList from '$lib/components/today/AwayList.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  // The seeded cockpit narrative's Priya Nair entry — Task 18 stopped
  // rendering it (and its rich seed copy) inline via `InquiryTriageCard
  // {item}`; that card is now generalized (`{path, fromName, summary,
  // sources}` props) and rendered separately below: once, fed this exact
  // payload entry's summary/usedSources, when mail isn't configured (so the
  // seed card looks IDENTICAL to the pre-Task-18 render), or once per real
  // review message with generic copy when it is. This title also filters
  // the entry back out of the generic `PreparedItemCard` loop so it doesn't
  // render twice.
  const SEED_INQUIRY_TITLE = 'Priya Nair · new inquiry';

  let today: CockpitToday | null = $state(null);
  let failed = $state(false);
  let loading = $state(true);

  async function load() {
    loading = true;
    failed = false;
    await refresh();
    loading = false;
  }

  // Silent variant of `load()` — refetches/replaces `today` without ever
  // flashing the skeleton. Used by the `mail_status` subscription below: the
  // payload's `mail` counts are computed backend-side at request time, and
  // the Engine activates ASYNCHRONOUSLY after workspace open (its
  // `mail_summary` reports zero/unconfigured until then — see
  // `Valea.Cockpit`'s `live_mail_summary/0` doc), so a Today that only ever
  // loaded once at mount would freeze that pre-activation snapshot forever.
  async function refresh() {
    const result = await api.cockpitToday();
    if (result.ok) {
      today = normalizeCockpitToday(result.data as Record<string, any>);
    } else if (loading) {
      // Only the initial mount-time load surfaces a failure state; a failed
      // background refresh keeps showing the last good narrative instead of
      // tearing the whole page down.
      failed = true;
    }
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
    // Unfreeze the cockpit snapshot on every `mail_status` push (Engine
    // activation, credential set, settings save, sync finish — each can
    // change `mail.configured` or the counts). Subscribed via the mail
    // store rather than a second `channel.on` binding — see
    // `MailStore#onMailStatus`'s doc comment. Unsubscribed on unmount.
    return mailStore.onMailStatus(() => void refresh());
  });

  const icmNav = $derived(icmToNav(flattenMountGroups(icmStore.groups)));
  const trust = $derived.by(() => splitTrustClause(today?.summary ?? ''));

  const otherPreparedItems = $derived.by(() =>
    (today?.preparedItems ?? []).filter((item) => item.title !== SEED_INQUIRY_TITLE)
  );

  // The cockpit payload's own Priya Nair entry — its summary/usedSources are
  // handed to the seed card below so the unconfigured render stays sourced
  // from the payload (byte-identical to the pre-Task-18 `{item}` render),
  // with the card's own SEED_* defaults as the fallback if this entry is
  // ever absent.
  const seedInquiry = $derived.by(() =>
    (today?.preparedItems ?? []).find((item) => item.title === SEED_INQUIRY_TITLE)
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
                  summary={genericSummary(subjectLabel(message.subject))}
                  sources={[]}
                  triageWorkflowPath={today.triageWorkflowPath}
                />
              {/each}
            {:else}
              <InquiryTriageCard
                summary={seedInquiry?.summary}
                sources={seedInquiry?.usedSources}
                triageWorkflowPath={today.triageWorkflowPath}
              />
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
