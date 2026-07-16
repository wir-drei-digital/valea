<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { api } from '$lib/api/client';
  import { AppShell, Sidebar } from '$lib/components/shell';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';
  import { normalizeCockpitToday, splitTrustClause, mailSummaryLine, type CockpitToday } from '$lib/today/cockpit';
  import ScheduleList from '$lib/components/today/ScheduleList.svelte';
  import OpenLoops from '$lib/components/today/OpenLoops.svelte';
  import AwayList from '$lib/components/today/AwayList.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  // Spec D deletion wave: this is an INTERIM trim, not the final page — the
  // whole "Prepared for you" section (its per-item cards, the queue-backed
  // prepare flow, and the "Distill recent decisions" action) is gone along
  // with the whole queue/workflow subsystem. What remains still renders
  // straight off the unchanged `cockpit_today` payload: schedule, open
  // loops, the away list, and the mail summary line. A later task rewrites
  // this page wholesale.

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
    // Unfreeze the cockpit snapshot on every `mail_status` push (Engine
    // activation, credential set, settings save, sync finish — each can
    // change `mail.configured` or the counts). Subscribed via the mail
    // store rather than a second `channel.on` binding — see
    // `MailStore#onMailStatus`'s doc comment. Unsubscribed on unmount.
    return mailStore.onMailStatus(() => void refresh());
  });

  // Task 9.3: the sidebar's file tree is gone (Knowledge owns it now) — see
  // `AppFrame.svelte`'s identical derivation, which every other route gets
  // for free. Today composes `Sidebar` directly rather than through
  // `AppFrame` (its `main` snippet doesn't fit AppFrame's shape), so it
  // derives `activeMountKey` the same way here.
  const activeMountKey = $derived(
    resolveActiveMountKey(page.url.pathname, page.url.searchParams, recentSessionsStore.groups)
  );
  const trust = $derived.by(() => splitTrustClause(today?.summary ?? ''));
</script>

<AppShell>
  {#snippet sidebar()}
    <Sidebar workspaceName={workspaceStore.name ?? 'Workspace'} {activeMountKey} />
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
