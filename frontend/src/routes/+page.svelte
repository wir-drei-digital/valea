<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { AppShell, MainColumn, Sidebar } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { gitStore, resolveGitConflict, type GitRepoStatus } from '$lib/stores/git.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';
  import { normalizeCockpitToday, type CockpitToday } from '$lib/today/cockpit';
  import { dateOverline, daySummarySegments, greetingForHour } from '$lib/today/greeting';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import { formatTimestamp } from '$lib/today/today-view';
  import AgentBriefingCard from '$lib/components/today/AgentBriefingCard.svelte';
  import AttentionCard from '$lib/components/today/AttentionCard.svelte';
  import { Composer } from '$lib/components/agent';
  import { Button } from '$lib/components/ui/button/index.js';
  import { NativeSelect } from '$lib/components/ui/native-select/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  // Today, as an actionable cockpit (Today/Tasks redesign §Part 1). The page is
  // an editorial column plus a quiet rail: greeting header, composer, the ONE
  // interrupt card, then the agent's briefings — the `today.json` files agents
  // maintain at the root of each ICM, which Valea itself never writes (see
  // `Valea.Cockpit.today/0`'s moduledoc).
  //
  // The old shape put those files in charge of the whole page: a section
  // existed only where one did, and the per-ICM tasks line lived inside it, so
  // a workspace with 34 open tasks and no `today.json` rendered "Nothing
  // prepared yet" and nothing else. Now every enabled ICM reports its briefing
  // file's state (`todayJson`) and the day's real work is read from the
  // ledgers, independently of it.
  //
  // MID-REBUILD (Task 10 of the redesign): the tasks section, the agenda, the
  // rail's cards and the whole-page empty state land in Task 11. The `<aside>`
  // below is deliberately in place and empty.

  let today: CockpitToday | null = $state(null);
  let failed = $state(false);
  let loading = $state(true);

  // The local clock, held as STATE and re-read on a timer rather than computed
  // once: this app stays open for days, and a `$derived` with no dependencies
  // would still be saying "Good morning" under yesterday's date at midnight.
  let now = $state(new Date());

  async function load() {
    loading = true;
    failed = false;
    await refresh();
    loading = false;
  }

  // Silent variant of `load()` — refetches/replaces `today` without ever
  // flashing the skeleton. Two independent pushes drive this (both wired
  // from `onMount` below): `mail_status` (the payload's `mail` counts are
  // computed backend-side at request time, and the Engine activates
  // ASYNCHRONOUSLY after workspace open — see `Valea.Cockpit`'s
  // `live_mail_summary/0` doc) and `icm_changed` (a `today.json` file
  // changed on disk — since Valea never writes that file itself, this push
  // is the ONLY way the page learns a section's content moved).
  async function refresh() {
    const result = await api.cockpitToday();
    if (result.ok) {
      today = normalizeCockpitToday(result.data as Record<string, any>);
      // `today.git` is deliberately NOT fed into `gitStore` here. It is read
      // from the same `Engine.statuses()` cache the `git_status` RPC reads, so
      // it is never fresher — but this reply can LAND later than a push, and
      // seeding from it would re-install a conflict the newest pass had
      // already cleared (the row and the sidebar dot would come back until the
      // next poll). The store's own `refresh()` covers cold load; the push
      // covers everything after.
    } else if (loading) {
      // Only the initial mount-time load surfaces a failure state; a failed
      // background refresh keeps showing the last good payload instead of
      // tearing the whole page down.
      failed = true;
    }
  }

  onMount(() => {
    void load();
    // First render of the shared sidebar — populate the ICM tree once here;
    // live refetch wiring (workspace:events) lands via the stores below.
    void icmStore.refetch();
    // Unfreeze the cockpit snapshot on every relevant push — see `refresh`'s
    // doc comment above. Both stores ride the ONE shared `workspace:events`
    // join (`wireIcmEvents`, `routes/+layout.svelte`'s call site); this page
    // subscribes to their listener sets rather than opening a second,
    // racing `channel.on(...)` binding of its own. Unsubscribed on unmount.
    const unsubMail = mailStore.onMailStatus(() => void refresh());
    const unsubIcm = icmStore.onIcmChanged(() => void refresh());

    // Midnight watch (L6). A minute's granularity is plenty for a date, and the
    // `visibilitychange` read catches the machine that was asleep at 00:00 and
    // is looked at again at 09:00 — timers do not reliably fire while suspended.
    const tick = setInterval(() => (now = new Date()), 60_000);
    const onVisible = () => {
      if (!document.hidden) now = new Date();
    };
    document.addEventListener('visibilitychange', onVisible);

    return () => {
      unsubMail();
      unsubIcm();
      clearInterval(tick);
      document.removeEventListener('visibilitychange', onVisible);
    };
  });

  // Task 9.3: the sidebar's file tree is gone (Knowledge owns it now) — see
  // `AppFrame.svelte`'s identical derivation, which every other route gets
  // for free. Today composes `Sidebar` directly rather than through
  // `AppFrame` (its `main` snippet doesn't fit AppFrame's shape), so it
  // derives `activeMountKey` the same way here.
  const activeMountKey = $derived(
    resolveActiveMountKey(page.url.pathname, page.url.searchParams, recentSessionsStore.groups)
  );

  // Git attention rows (ICM git sync spec §UI). Read straight off `gitStore`
  // — NOT off `today.git` — so an engine push updates this card without a
  // cockpit round trip, and so a momentarily empty payload can't blank it
  // (the store's keep-on-empty policy). The store has exactly TWO feeds, and
  // this route's `refresh()` is neither: `gitStore.refresh()` (the
  // `git_status` RPC — cold load, and workspace switch via
  // `refreshSidebarProjectStores`) and the `git_status` push. The cockpit
  // payload is deliberately not a third one — see `GitStore`'s own note.
  const gitAttention = $derived(gitStore.attentionRepos);

  // The two notice kinds that are genuinely INTERRUPTS — a run parked on a
  // permission ask, and a run that failed. `registered` is an FYI and belongs
  // on the rail (Task 11); it is filtered out here rather than dropped from the
  // payload, which still carries it.
  //
  // `$derived.by` rather than `$derived`: the expression form is analyzed in
  // the declaration's own control flow, where `today` is still narrowed to the
  // `null` it was initialized with (`today?.scheduleNotices` then reads as
  // `never`).
  const interruptNotices = $derived.by(
    () =>
      today?.scheduleNotices.filter(
        (notice) => notice.kind === 'waiting' || notice.kind === 'failed'
      ) ?? []
  );

  /** Exactly what `AttentionCard` renders — the summary line must never promise a row the card doesn't have. */
  const attentionCount = $derived(gitAttention.length + interruptNotices.length);

  const summary = $derived(
    daySummarySegments({
      // Task 11 wires the real counts (they come from the task ledgers via
      // `tasksStore`, which this page does not read yet) and the agenda's
      // `nextEventTime`. Zero and `null` drop their segments, so the line is
      // simply shorter until then rather than wrong.
      todayCount: 0,
      overdueCount: 0,
      attentionCount,
      nextEventTime: null
    })
  );

  // Quick composer: start a session straight from the cockpit — no detour
  // through /chat's empty state. The picker names the target (so the
  // placeholder doesn't have to); its default is the ICM the user last worked
  // in, and an explicit pick lasts for the visit only — MRU wins again on the
  // next load, which is why nothing here is persisted.
  const quickTarget = $derived(
    mostRecentMountKey(recentSessionsStore.groups, icmStore.groups[0]?.mount ?? null)
  );

  let quickMountKey = $state('');

  // Seeds the picker from the MRU once the ICM list arrives, and repairs it if
  // the selected ICM disappears (unmounted mid-session) — the TasksTab
  // quick-add pattern, verbatim.
  $effect(() => {
    const keys = icmStore.groups.map((group) => group.mount);
    if (keys.length === 0) return;
    if (!keys.includes(quickMountKey)) {
      quickMountKey = quickTarget !== null && keys.includes(quickTarget) ? quickTarget : keys[0];
    }
  });

  /** The mount whose handoff is in flight — every Resolve button is disabled while one runs. */
  let resolving = $state<string | null>(null);
  let resolveError = $state<Record<string, string>>({});

  async function resolveConflict(repo: GitRepoStatus): Promise<void> {
    if (resolving) return;
    resolving = repo.mountKey;
    resolveError = { ...resolveError, [repo.mountKey]: '' };
    try {
      const outcome = await resolveGitConflict(repo, workspaceStore.generation ?? 0);
      if (outcome.ok) {
        void goto(`/chat?session=${outcome.sessionId}`);
      } else {
        // The message is the backend's own sentence (git errors carry no
        // machine codes); the store already refreshed the rows, so a conflict
        // that just cleared takes its row with it.
        resolveError = { ...resolveError, [repo.mountKey]: outcome.error };
      }
    } finally {
      resolving = null;
    }
  }

  let quickBusy = $state(false);
  let quickError = $state<string | null>(null);

  async function quickStart(text: string): Promise<void> {
    const mountKey = quickMountKey;
    if (!mountKey || quickBusy) return;
    quickBusy = true;
    quickError = null;
    try {
      const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0);
      if (!result.ok) {
        quickError =
          result.error === 'harness_unavailable'
            ? "The assistant isn't ready — open Settings → Agent (the gear in the sidebar) and run the checks."
            : 'The session could not be started. Please try again.';
        return;
      }
      const data = result.data as { id: string };
      setInitialPrompt(data.id, text);
      void recentSessionsStore.refresh();
      void goto(`/chat?session=${data.id}`);
    } finally {
      quickBusy = false;
    }
  }
</script>

<AppShell>
  {#snippet sidebar()}
    <Sidebar {activeMountKey} />
  {/snippet}

  {#snippet main()}
    <MainColumn wide>
      <!-- Editorial column + rail (spec §Layout). The pair is centered inside
           the full-width pane — the 660px prose cap this page used to take is
           exactly what the redesign retires. Under 1180px the rail folds under
           the column and its cards go full-width. -->
      <div
        class="mx-auto grid w-full max-w-[1220px] grid-cols-1 gap-8 min-[1180px]:grid-cols-[minmax(0,880px)_300px]"
      >
        <div class="min-w-0">
          {#if loading}
            <div class="flex flex-col gap-6" aria-hidden="true">
              <div class="flex flex-col gap-2">
                <Skeleton class="h-3 w-40" />
                <Skeleton class="h-7 w-56" />
              </div>
              <Skeleton class="h-14 w-full rounded-[14px]" />
              <Skeleton class="h-24 w-full rounded-xl" />
            </div>
          {:else if failed || !today}
            <div class="flex flex-col items-start gap-3 py-10">
              <p class="text-ink-body text-[13.5px]">
                Couldn't load your day. The backend may still be starting.
              </p>
              <Button variant="outline" size="sm" onclick={() => void load()}>Retry</Button>
            </div>
          {:else}
            <div class="flex flex-col gap-6">
              <header class="flex flex-col gap-1.5">
                <p class="text-overline">{dateOverline(now)}</p>
                <h1 class="font-display text-ink-heading text-[28px] leading-tight font-medium">
                  {greetingForHour(now.getHours())}
                </h1>
                {#if summary.length > 0}
                  <p class="text-[13px]">
                    {#each summary as segment, i (segment.text)}
                      {#if i > 0}<span class="text-ink-meta"> · </span>{/if}
                      <span class={segment.tone === 'warn' ? 'text-warn-ink font-medium' : 'text-ink-meta'}>
                        {segment.text}
                      </span>
                    {/each}
                  </p>
                {/if}
              </header>

              {#if quickMountKey}
                <!-- The picker sits on the composer's left edge and names the
                     target, so the placeholder no longer has to. Two bits of
                     geometry against the Composer's own dock: the negative
                     margins cancel its `px-4`, landing the card's edges on the
                     column's, and `mt-4` centers the 32px select on the card's
                     first row (4px dock padding + 1px border + 12px card
                     padding + half of the 30px row). -->
                <div>
                  <div class="flex items-start gap-2">
                    <NativeSelect
                      aria-label="Project for the new session"
                      bind:value={quickMountKey}
                      disabled={quickBusy}
                      class="mt-4 w-auto max-w-[180px] shrink-0"
                    >
                      {#each icmStore.groups as group (group.mount)}
                        <option value={group.mount}>{group.title || group.mount}</option>
                      {/each}
                    </NativeSelect>
                    <div class="-mx-4 min-w-0 flex-1">
                      <Composer
                        busy={quickBusy}
                        configItems={[]}
                        placeholder="Start a session…"
                        onSend={(text) => void quickStart(text)}
                        onStop={() => {}}
                        onSetConfig={() => {}}
                      />
                    </div>
                  </div>
                  {#if quickError}
                    <p class="text-warn-ink text-[12.5px]" role="alert">{quickError}</p>
                  {/if}
                </div>
              {/if}

              <AttentionCard
                gitRows={gitAttention}
                notices={interruptNotices}
                {resolving}
                {resolveError}
                onResolve={(repo) => void resolveConflict(repo)}
              />

              <!-- The agent's briefings, one card per ICM whose `today.json`
                   is readable. `unreadable` gets the calm note below instead of
                   a card, and `absent` renders nothing at all — no placeholder
                   box asking for a file. -->
              {#each today.sections.filter((s) => s.todayJson === 'present') as section (section.mountKey)}
                <AgentBriefingCard {section} />
              {/each}

              {#each today.sections.filter((s) => s.todayJson === 'unreadable') as section (section.mountKey)}
                <!-- Leniency contract: `today.json` is the user's file, and one
                     we can't parse is a thing to fix, not an app error. -->
                <div>
                  <h2 class="text-overline">{section.icmName || section.mountKey}</h2>
                  <p class="text-ink-meta mt-1 text-[13px]">today.json couldn't be read</p>
                </div>
              {/each}

              {#if today.recentSessions.length > 0}
                <!-- Task 11 re-homes this to the rail, where it becomes the
                     third quiet card; it stays in the column meanwhile so the
                     page doesn't lose a working affordance mid-rebuild. -->
                <section class="pb-6">
                  <h2 class="text-overline mb-2">Recent sessions</h2>
                  <ul class="flex flex-col">
                    {#each today.recentSessions as session (session.id)}
                      <li>
                        <a
                          href={`/chat?session=${session.id}`}
                          class="text-ink-secondary hover:bg-paper-pill flex items-center gap-2 rounded-md py-1.5 text-[13px] transition-colors"
                        >
                          {#if session.live}
                            <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                          {:else}
                            <span class="size-1.5 shrink-0" aria-hidden="true"></span>
                          {/if}
                          <span class="min-w-0 flex-1 truncate">{session.title}</span>
                          <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">
                            {formatTimestamp(session.startedAt)}
                          </span>
                        </a>
                      </li>
                    {/each}
                  </ul>
                </section>
              {/if}
            </div>
          {/if}
        </div>

        <aside class="flex min-w-0 flex-col gap-3">
          <!-- Task 11: rail cards -->
        </aside>
      </div>
    </MainColumn>
  {/snippet}
</AppShell>
