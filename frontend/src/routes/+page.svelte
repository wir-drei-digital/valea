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
  import { normalizeCockpitToday, scheduleNoticeHref, scheduleNoticeText, type CockpitToday } from '$lib/today/cockpit';
  import { dateOverline, daySummarySegments, greetingForHour } from '$lib/today/greeting';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import {
    formatTimestamp,
    hasBriefing,
    nextEventTime,
    railMailRows,
    unreadableLedgerNotes
  } from '$lib/today/today-view';
  import { minutesOfDay, type CalendarEvent } from '$lib/components/calendar/calendar-shapes';
  import {
    isCompleted,
    localDateIso,
    orderTaskRows,
    overdueDays,
    todayFilter,
    type TaskEntry
  } from '$lib/tasks/filters';
  import { tasksSettings } from '$lib/tasks/settings.svelte';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import AgendaSection from '$lib/components/today/AgendaSection.svelte';
  import AgentBriefingCard from '$lib/components/today/AgentBriefingCard.svelte';
  import AttentionCard from '$lib/components/today/AttentionCard.svelte';
  import RailCard from '$lib/components/today/RailCard.svelte';
  import TodayTasks from '$lib/components/today/TodayTasks.svelte';
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
  // LEDGERS, independently of it — `tasksStore`, the same store the Tasks page
  // writes through, which is what makes the rows here live rather than a
  // read-only summary.
  //
  // Three feeds, three refresh paths, deliberately kept apart: the cockpit
  // payload (`refresh()` below), the task ledgers (`tasksStore`, re-listed on
  // the same `icm_changed` push), and git (`gitStore`, its own RPC + push).

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
    // The day's real work. `tasks.json` is a plain file in a user-owned ICM
    // root that agents and hands edit directly, so the `icm_changed` push is
    // how this page learns a row moved — the Tasks route's wiring, narrowed to
    // the ONE list this page reads (`refresh()` would also re-list every
    // schedule; Today's schedule notices ride the cockpit payload instead).
    void tasksStore.refreshTasks();
    // Unfreeze the cockpit snapshot on every relevant push — see `refresh`'s
    // doc comment above. Both stores ride the ONE shared `workspace:events`
    // join (`wireIcmEvents`, `routes/+layout.svelte`'s call site); this page
    // subscribes to their listener sets rather than opening a second,
    // racing `channel.on(...)` binding of its own. Unsubscribed on unmount.
    const unsubMail = mailStore.onMailStatus(() => void refresh());
    const unsubIcm = icmStore.onIcmChanged(() => {
      void refresh();
      void tasksStore.refreshTasks();
    });

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

  // -- the day's work ---------------------------------------------------------

  /**
   * Local calendar date — "due today" is a wall-clock question, and the backend
   * asks it in the host zone (`Valea.Cockpit.tasks_line/2`). Derived from the
   * ticking `now` above, so the midnight watch moves the filter too.
   */
  const todayIso = $derived(localDateIso(now));

  /** The persisted Today toggle (spec §Persistence). `TodayTasks` owns the control; the row set is derived here. */
  const mineOnly = $derived(tasksSettings.todayAssignee === 'user');

  /**
   * The today view across every ledger, assignee-narrowed and ordered — the
   * ONE derivation of the day's rows. `TodayTasks` renders it and the header's
   * summary line counts it; a component that recomputed its own set could
   * disagree with the sentence above it, which is exactly the count dishonesty
   * the redesign is fixing.
   *
   * Rows are collected first and sorted as ONE list: `taskIcms` arrives
   * ICM-major, and a day ordered by project is not ordered at all.
   */
  const merged = $derived.by((): { icm: TaskIcm; task: TaskEntry }[] => {
    const owner = new Map<TaskEntry, TaskIcm>();
    const rows: TaskEntry[] = [];
    for (const icm of tasksStore.taskIcms) {
      for (const task of todayFilter(icm.tasks, todayIso)) {
        if (mineOnly && (task.assignee ?? 'user') !== 'user') continue;
        owner.set(task, icm);
        rows.push(task);
      }
    }
    return orderTaskRows(rows).flatMap((task) => {
      const icm = owner.get(task);
      return icm === undefined ? [] : [{ icm, task }];
    });
  });

  const overdueCount = $derived(merged.filter(({ task }) => overdueDays(task, todayIso) !== null).length);

  /**
   * Whether the tasks section has anything to say AT ALL — open work anywhere,
   * in or out of today's view, whatever the toggle hides. It gates the section
   * (so the toggle and the tail line stay reachable when today itself is empty)
   * and, inverted, it is one term of the whole-page empty state. One predicate
   * for both, so the welcome card can never appear beside a task list.
   */
  const openTaskCount = $derived(
    tasksStore.taskIcms.reduce((sum, icm) => sum + icm.tasks.filter((task) => !isCompleted(task)).length, 0)
  );

  /**
   * The OTHER thing the tasks section can have to say: a ledger Valea could not
   * parse. It yields no rows, so `openTaskCount` cannot see it — and a page that
   * counted only rows would offer the welcome card ("add a task and it shows up
   * here") to a user whose tasks are sitting in a broken file. The section keeps
   * itself visible for these notes, and `dayIsEmpty` below stands down for them.
   * `TodayTasks` renders the same list through the same helper.
   */
  const ledgerNotes = $derived(unreadableLedgerNotes(tasksStore.taskIcms));

  // -- agenda -----------------------------------------------------------------

  /** The zone the agenda's day range is interpreted in — the calendar route's own resolution. */
  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  /** Today's timed events, handed up by `AgendaSection` on a successful load (see its `onEvents` doc). */
  let agendaEvents = $state<CalendarEvent[]>([]);
  /** Whether the agenda has ANSWERED yet — a day that hasn't loaded is not an empty day. */
  let agendaSettled = $state(false);

  const summary = $derived(
    daySummarySegments({
      // `todayCount` is post-toggle and includes overdue — they are today's
      // work too (`daySummarySegments`' own contract).
      todayCount: merged.length,
      overdueCount,
      attentionCount,
      nextEventTime: nextEventTime(agendaEvents, minutesOfDay(now))
    })
  );

  // -- rail -------------------------------------------------------------------

  const configuredMail = $derived.by(() => today?.mail.filter((account) => account.configured) ?? []);
  const mailRows = $derived(railMailRows(configuredMail, 4));
  /** The FYI half of the notices — `waiting`/`failed` are interrupts and belong to `AttentionCard`. */
  const registeredNotices = $derived.by(
    () => today?.scheduleNotices.filter((notice) => notice.kind === 'registered') ?? []
  );
  const recentSessions = $derived.by(() => today?.recentSessions.slice(0, 5) ?? []);

  // -- the empty day ----------------------------------------------------------

  /** Briefing cards plus unreadable notes — what the sections loop actually paints (`hasBriefing` is the card's own guard). */
  const briefingCount = $derived.by(
    () =>
      today?.sections.filter(
        (section) =>
          (section.todayJson === 'present' && hasBriefing(section)) || section.todayJson === 'unreadable'
      ).length ?? 0
  );

  /**
   * Nothing on the page, anywhere — the one case that earns the welcome card
   * (spec §Empty page). Every term is the SAME predicate the corresponding
   * region renders on, so the card cannot appear beside content.
   *
   * The agenda term is "disabled, or answered and empty": a fetch still in
   * flight is not an empty day, and a FAILED one never reports (see
   * `AgendaSection`'s `onEvents`), so its error line is never joined by a card
   * claiming there is nothing to show. `tasksLoaded` is the same rule for the
   * ledgers, and it matters twice: `list_tasks` resolves LATER than the cockpit
   * RPC (so the card would flash on every cold load), and a list that never
   * arrives at all must not be rendered as a workspace with nothing in it —
   * the one thing the leniency contract forbids outright. `ledgerNotes` is that
   * same rule one level down: a ledger that arrived UNREADABLE is a workspace
   * whose contents we cannot see, not an empty one.
   */
  const dayIsEmpty = $derived.by(
    () =>
      tasksStore.tasksLoaded &&
      attentionCount === 0 &&
      briefingCount === 0 &&
      openTaskCount === 0 &&
      ledgerNotes.length === 0 &&
      ((today?.calendar ?? null) === null || (agendaSettled && agendaEvents.length === 0)) &&
      configuredMail.length === 0 &&
      registeredNotices.length === 0 &&
      recentSessions.length === 0
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
           exactly what the redesign retires.
           The fold is a CONTAINER query, not a viewport one: the sidebar
           (236px) and this pane's gutters (64px) are not the page's to spend,
           so a 1180px VIEWPORT leaves the column ~548px — narrower than the cap
           being retired, which is the opposite of the intent. `@container` on
           the wrapper makes the pane's own width the question, and 1212px is
           what the two regions actually need (880 + 32 gap + 300). -->
      <div class="@container">
        <div
          class="mx-auto grid w-full max-w-[1220px] grid-cols-1 gap-8 @min-[1212px]:grid-cols-[minmax(0,880px)_300px]"
        >
          <div class="min-w-0">
            {#if loading}
              <!-- Sketches the shape that is coming, in its order: overline +
                   greeting, the composer's row, one card, then two task rows. -->
              <div class="flex flex-col gap-6" aria-hidden="true">
                <div class="flex flex-col gap-2">
                  <Skeleton class="h-3 w-40" />
                  <Skeleton class="h-7 w-56" />
                  <Skeleton class="h-3 w-64" />
                </div>
                <Skeleton class="h-14 w-full rounded-[14px]" />
                <Skeleton class="h-24 w-full rounded-xl" />
                <div class="flex flex-col gap-2">
                  <Skeleton class="h-3 w-24" />
                  <Skeleton class="h-8 w-full" />
                  <Skeleton class="h-8 w-full" />
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
              <div class="flex flex-col gap-6">
                <header class="flex flex-col gap-1.5">
                  <p class="text-overline">{dateOverline(now)}</p>
                  <h1 class="font-display text-ink-heading text-[28px] leading-tight font-medium">
                    {greetingForHour(now.getHours())}
                  </h1>
                  {#if summary.length > 0}
                    <p class="text-[13px]">
                      <!-- The separator's spacing is a MARGIN, not the two spaces
                           it used to be written with: Svelte trims leading and
                           trailing whitespace inside an element, so `<span> ·
                           </span>` shipped as a bare `·` and the line read
                           "5 tasks for today· 2 overdue". -->
                      {#each summary as segment, i (segment.text)}
                        {#if i > 0}<span class="text-ink-meta mx-1" aria-hidden="true">·</span>{/if}
                        <span class={segment.tone === 'warn' ? 'text-warn-ink font-medium' : 'text-ink-meta'}>
                          {segment.text}
                        </span>
                      {/each}
                    </p>
                  {/if}
                </header>

                <!-- Gated on the GROUPS, not on the seeded pick: `quickMountKey`
                     is empty until the seeding `$effect` runs, which is a flush
                     later than the render that brought the groups in — gating on
                     it painted the composer one frame late, on top of the pop-in
                     the reserved row below now absorbs. (An ICM the tree dropped
                     but recent sessions still remember has no option to select,
                     so the picker can't offer it; same trade TasksTab's
                     quick-add makes.) -->
                {#if icmStore.groups.length > 0 || quickMountKey !== ''}
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
                {:else if !icmStore.loaded && icmStore.listError === null}
                  <!-- The ICM tree resolves LATER than the cockpit payload (it
                       is a list plus a root listing per mount), so the page
                       leaves its skeleton before it knows whether there is
                       anything to start a session in. Hold the composer's exact
                       height until it does — otherwise every cold load paints a
                       complete column and then shoves it down. Not rendered once
                       the tree has answered: a workspace with no projects gets
                       Task 11's empty state, not a 76px hole. -->
                  <div class="h-[76px]" aria-hidden="true"></div>
                {/if}

                <AttentionCard
                  gitRows={gitAttention}
                  notices={interruptNotices}
                  {resolving}
                  {resolveError}
                  onResolve={(repo) => void resolveConflict(repo)}
                />

                <!-- The agent's briefings, in PAYLOAD ORDER — one pass, not one
                     pass per state: two filtered loops sorted every unreadable
                     note below every card, so a project's calm note detached
                     from the projects around it. `present` gets a card (the card
                     itself declines to paint an empty briefing), `unreadable`
                     gets the calm note, `absent` renders nothing at all — no
                     placeholder box asking for a file. -->
                {#each today.sections as section (section.mountKey)}
                  {#if section.todayJson === 'present'}
                    <AgentBriefingCard {section} />
                  {:else if section.todayJson === 'unreadable'}
                    <!-- Leniency contract: `today.json` is the user's file, and
                         one we can't parse is a thing to fix, not an app error. -->
                    <div>
                      <h2 class="text-overline">{section.icmName || section.mountKey}</h2>
                      <p class="text-ink-meta mt-1 text-[13px]">today.json couldn't be read</p>
                    </div>
                  {/if}
                {/each}

                {#if tasksStore.tasksFailed}
                  <!-- Calm, and scoped: the ledgers are one of this page's three
                       feeds, and the rest of the day still renders. Silence here
                       would be the leniency contract's cardinal sin — an
                       unreachable list shown as an empty one. `tasksFailed` is
                       set only when the list has NEVER loaded, so a failed
                       background re-list keeps the rows it already has. -->
                  <p class="text-ink-meta text-[13px]">Couldn't read your tasks.</p>
                {:else if openTaskCount > 0 || ledgerNotes.length > 0}
                  <!-- Gated on open work ANYWHERE, not on today's rows: the
                       section keeps its toggle and its tail line on screen when
                       today itself is empty, which is the way back from a
                       toggle that just hid everything. An unreadable ledger
                       counts as something to say on its own — it has a calm note
                       and no rows to carry it. -->
                  <TodayTasks {merged} {todayIso} />
                {/if}

                <!-- Hidden entirely unless the cockpit says the calendar
                     subsystem has something to say; a configured-but-empty day
                     gets the quiet line, not silence. -->
                <AgendaSection
                  enabled={today.calendar !== null}
                  {todayIso}
                  {zone}
                  onEvents={(events) => {
                    agendaEvents = events;
                    agendaSettled = true;
                  }}
                />

                {#if dayIsEmpty}
                  <!-- The whole-page empty state (spec §Empty page): plain
                       language about what this page will hold, and the two ways
                       to put something in it. No file names — a first-run user
                       has no reason to know what a `today.json` is. -->
                  <div class="bg-paper-card border-paper-border rounded-xl border p-5">
                    <p class="text-ink-body text-[13.5px] leading-relaxed">
                      <strong class="text-ink-heading">Your day, once there's something in it.</strong>
                      Each project keeps a shared task list you and the assistant both work from — add a task
                      on the <a href="/tasks" class="underline">Tasks</a> page and it shows up here. You can also
                      ask the assistant to prepare a morning briefing for any project; it appears at the top of
                      this page.
                    </p>
                  </div>
                {/if}
              </div>
            {/if}
          </div>

          <!-- The rail: three quiet cards, each rendered only with content
               (spec §Rail). It folds under the column below 1212px of PANE
               width — see the grid's note above. -->
          <aside class="flex min-w-0 flex-col gap-3">
            {#if loading}
              <div aria-hidden="true"><Skeleton class="h-28 w-full rounded-xl" /></div>
            {:else if today && !failed}
              {#if configuredMail.length > 0}
                <RailCard overline="New mail">
                  {#if mailRows.length > 0}
                    <ul class="mb-2 flex flex-col">
                      {#each mailRows as row (`${row.account}/${row.msgId}`)}
                        <li>
                          <!-- The old New-mail section's deep link, verbatim:
                               account + message id, both encoded (they come off
                               a maildir, not a controlled vocabulary). -->
                          <a
                            href={`/mail?account=${encodeURIComponent(row.account)}&message=${encodeURIComponent(row.msgId)}`}
                            class="hover:bg-paper-pill flex items-baseline gap-2 rounded-md py-1 pr-1.5 transition-colors"
                          >
                            <span class="bg-act size-1.5 shrink-0 self-center rounded-full" aria-hidden="true"></span>
                            <span class="text-ink-body min-w-0 flex-1 truncate text-[12.5px]">{row.line}</span>
                          </a>
                        </li>
                      {/each}
                    </ul>
                  {/if}
                  <!-- One footer line per CONFIGURED account, including the ones
                       with nothing unread: "0 unread" is the answer to "is my
                       mail working", and it is the only place this page still
                       says anything about an account's state. -->
                  {#each configuredMail as account (account.account)}
                    <a
                      href={`/mail?account=${encodeURIComponent(account.account)}`}
                      class="text-ink-meta hover:text-ink-heading flex items-baseline gap-1 text-[11.5px] hover:underline"
                    >
                      <span class="min-w-0 truncate">{account.account}</span>
                      <span class="shrink-0 tabular-nums">· {account.unreadCount} unread</span>
                    </a>
                  {/each}
                </RailCard>
              {/if}

              {#if registeredNotices.length > 0}
                <RailCard overline="Schedules">
                  <ul class="flex flex-col">
                    {#each registeredNotices as notice, i (`${notice.mountKey ?? ''}/${notice.scheduleId}/${i}`)}
                      <li>
                        <a
                          href={scheduleNoticeHref(notice)}
                          class="hover:bg-paper-pill flex items-baseline gap-2 rounded-md py-1 pr-1.5 transition-colors"
                        >
                          <span class="text-ink-body min-w-0 flex-1 text-[12.5px]">{scheduleNoticeText(notice)}</span>
                          {#if notice.at}
                            <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">
                              {formatTimestamp(notice.at)}
                            </span>
                          {/if}
                        </a>
                      </li>
                    {/each}
                  </ul>
                </RailCard>
              {/if}

              {#if recentSessions.length > 0}
                <RailCard overline="Recent sessions">
                  <ul class="flex flex-col">
                    {#each recentSessions as session (session.id)}
                      <li>
                        <a
                          href={`/chat?session=${session.id}`}
                          class="text-ink-secondary hover:bg-paper-pill flex items-center gap-2 rounded-md py-1 pr-1.5 text-[12.5px] transition-colors"
                        >
                          {#if session.live}
                            <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                          {:else}
                            <span class="size-1.5 shrink-0" aria-hidden="true"></span>
                          {/if}
                          <span class="min-w-0 flex-1 truncate">{session.title}</span>
                          <span class="text-ink-meta shrink-0 text-[11px] tabular-nums">
                            {formatTimestamp(session.startedAt)}
                          </span>
                        </a>
                      </li>
                    {/each}
                  </ul>
                </RailCard>
              {/if}
            {/if}
          </aside>
        </div>
      </div>
    </MainColumn>
  {/snippet}
</AppShell>
