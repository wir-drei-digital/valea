<script lang="ts">
  import { onMount } from 'svelte';
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { api } from '$lib/api/client';
  import { AppShell, MainColumn, Sidebar } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import {
    gitStore,
    gitAttentionText,
    resolveGitConflict,
    type GitRepoStatus
  } from '$lib/stores/git.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';
  import { mountProvenanceLabel } from '$lib/shell/provenance';
  import { knowledgeHref } from '$lib/shell/nav';
  import {
    normalizeCockpitToday,
    calendarSummaryLine,
    mailSummaryLine,
    scheduleNoticeHref,
    scheduleNoticeText,
    tasksSummaryLine,
    type CockpitToday
  } from '$lib/today/cockpit';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import { Composer } from '$lib/components/agent';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';

  // Spec D §C rewrite: Today renders `today.json` files agents maintain at
  // the root of each ICM — Valea itself never writes them (see
  // `Valea.Cockpit.today/0`'s moduledoc). One block per enabled ICM that has
  // a readable file, plus the live state Valea owns (mail counts, recent
  // sessions).

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
      // The cockpit's git rows are the same rows `gitStore` holds, and this
      // page fetches them anyway — hand them over rather than render a second
      // copy. The store applies the busy-engine keep-on-empty policy, and it
      // is what the sidebar badge reads too, so the two can never disagree.
      //
      // `$state.snapshot`: PLAIN rows, not this page's `$state` proxies — two
      // stores holding the same proxied objects is the identity-comparison
      // trap `CalendarStore.#fetchToken` documents.
      gitStore.applyRows($state.snapshot(today.git) as GitRepoStatus[]);
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
    return () => {
      unsubMail();
      unsubIcm();
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

  function formatTimestamp(iso: string): string {
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return iso;
    return parsed.toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }

  // Quick composer: start a session in the most recently used ICM straight
  // from the cockpit — no detour through /chat's empty state. Target
  // selection mirrors the chat route's own default (first enabled mount)
  // when no session exists yet; the placeholder names the target so it's
  // never ambiguous where the session will run.
  const quickTarget = $derived(
    mostRecentMountKey(recentSessionsStore.groups, icmStore.groups[0]?.mount ?? null)
  );
  const quickTargetName = $derived.by(() => {
    if (!quickTarget) return null;
    return (
      recentSessionsStore.groups.find((g) => g.mountKey === quickTarget)?.icmName ??
      icmStore.groups.find((g) => g.mount === quickTarget)?.title ??
      quickTarget
    );
  });

  // Git attention rows (ICM git sync spec §UI). Read straight off `gitStore`
  // — NOT off `today.git` — so an engine push updates this section without a
  // cockpit round trip, and so a momentarily empty payload can't blank it
  // (the store's keep-on-empty policy). `refresh()` above keeps the store fed
  // from the cockpit payload; `refreshSidebarProjectStores` and the
  // `git_status` push are the other two feeds.
  const gitAttention = $derived(gitStore.attentionRepos);
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
    const mountKey = quickTarget;
    if (!mountKey || quickBusy) return;
    quickBusy = true;
    quickError = null;
    try {
      const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0);
      if (!result.ok) {
        quickError =
          result.error === 'harness_unavailable'
            ? "The assistant isn't ready — open Agent settings (gear in the sidebar) and run the checks."
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
    <MainColumn>
      {#if loading}
        <div class="flex flex-col gap-8" aria-hidden="true">
          <Skeleton class="h-6 w-32" />
          <div class="flex flex-col gap-3">
            <Skeleton class="h-3 w-28" />
            <Skeleton class="h-20 w-full rounded-xl" />
            <Skeleton class="h-20 w-full rounded-xl" />
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
          <h1 class="font-display text-ink-heading text-[22px] leading-tight font-medium">Today</h1>
          {#each today.mail.filter((m) => m.configured) as mail (mail.account)}
            <p class="text-ink-meta text-[13px]">{mailSummaryLine(mail)}</p>
          {/each}
          {#if today.calendar}
            <p class="text-ink-meta text-[13px]">{calendarSummaryLine(today.calendar)}</p>
          {/if}
        </header>

        {#if quickTarget}
          <div class="-mx-4 mt-4">
            <Composer
              busy={quickBusy}
              configItems={[]}
              placeholder={`Start a session in ${quickTargetName ?? 'your project'}…`}
              onSend={(text) => void quickStart(text)}
              onStop={() => {}}
              onSetConfig={() => {}}
            />
          </div>
          {#if quickError}
            <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{quickError}</p>
          {/if}
        {/if}

        {#if today.mail.some((m) => m.configured && m.unread.length > 0)}
          <!-- New emails by account — the unread INBOX window each account's
               cockpit entry carries; rows deep-link into /mail. -->
          <section class="mt-8">
            <p class="text-overline mb-2">New mail</p>
            <div class="flex flex-col gap-4">
              {#each today.mail.filter((m) => m.configured && m.unread.length > 0) as mail (mail.account)}
                <div>
                  <p class="text-ink-meta text-[12px]">
                    {mail.account}
                    <span class="tabular-nums">
                      · {mail.unreadCount} unread{mail.unreadCount > mail.unread.length ? `, newest ${mail.unread.length}` : ''}
                    </span>
                  </p>
                  <ul class="mt-1 flex flex-col">
                    {#each mail.unread as message (message.msgId)}
                      <li>
                        <a
                          href={`/mail?account=${encodeURIComponent(mail.account)}&message=${encodeURIComponent(message.msgId)}`}
                          class="hover:bg-paper-pill flex items-baseline gap-2 rounded-md py-1.5 pr-2 transition-colors"
                        >
                          <span class="bg-act size-1.5 shrink-0 self-center rounded-full" aria-hidden="true"></span>
                          <span class="text-ink-heading shrink-0 text-[13px] font-medium">
                            {message.fromName ?? message.fromEmail ?? '(unknown sender)'}
                          </span>
                          <span class="text-ink-body min-w-0 flex-1 truncate text-[13px]">
                            {message.subject ?? '(no subject)'}
                          </span>
                          {#if message.date}
                            <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">
                              {formatTimestamp(message.date)}
                            </span>
                          {/if}
                        </a>
                      </li>
                    {/each}
                  </ul>
                </div>
              {/each}
            </div>
          </section>
        {/if}

        {#if today.sections.length === 0}
          <div class="border-paper-border bg-paper-card mt-8 rounded-xl border p-5">
            <p class="text-ink-body text-[13.5px] leading-relaxed">
              <strong class="text-ink-heading">Nothing prepared yet.</strong>
              Today renders a
              <code class="bg-paper-track rounded px-1 py-0.5 text-[12.5px]">today.json</code>
              file from the root of each project. Your agent keeps it up to date with prepared
              work and notes; what needs doing lives in
              <a href="/tasks" class="underline">Tasks</a>. Ask your agent to maintain one; the
              starter project's
              <code class="bg-paper-track rounded px-1 py-0.5 text-[12.5px]">AGENTS.md</code> documents the
              shape.
            </p>
          </div>
        {:else}
          <div class="mt-8 flex flex-col gap-8">
            {#each today.sections as section (section.mountKey)}
              <section>
                <div class="flex items-baseline gap-2">
                  <span class="text-ink-meta text-[12px]">{mountProvenanceLabel(section.icmName)}</span>
                  {#if section.updatedAt}
                    <span class="text-ink-meta text-[11.5px] tabular-nums">
                      {formatTimestamp(section.updatedAt)}
                    </span>
                  {/if}
                </div>

                {#if !section.ok}
                  <p class="text-ink-meta mt-2 text-[13px]">today.json couldn't be read</p>
                {:else}
                  {#if section.notes}
                    <p class="text-ink-body mt-2 text-[13.5px]">{section.notes}</p>
                  {/if}

                  {#if section.prepared.length > 0}
                    <ul class="mt-3 flex flex-col gap-3">
                      {#each section.prepared as item, i (i)}
                        <li>
                          {#if item.page}
                            <a
                              href={knowledgeHref(section.mountKey, item.page)}
                              class="text-ink-heading text-[13.5px] font-medium hover:underline"
                            >
                              {item.title ?? '(untitled)'}
                            </a>
                          {:else}
                            <p class="text-ink-heading text-[13.5px] font-medium">
                              {item.title ?? '(untitled)'}
                            </p>
                          {/if}
                          {#if item.summary}
                            <p class="text-ink-body text-[13px]">{item.summary}</p>
                          {/if}
                        </li>
                      {/each}
                    </ul>
                  {/if}

                {/if}

                <!-- The tasks line (tasks+schedules spec §Cockpit) — it
                     REPLACED the `open_loops` array agents used to hand-
                     maintain in `today.json`. Rendered OUTSIDE the `ok` branch
                     above on purpose: it reads a DIFFERENT file, so a broken
                     `today.json` never hides real tasks (and vice versa —
                     `tasks: null` is the unreadable-ledger case). The full
                     view is `/tasks`; this is counts plus the top three. -->
                {#if section.tasks === null}
                  <p class="text-ink-meta mt-2 text-[13px]">
                    tasks.json is unreadable — fix by hand or ask the agent
                  </p>
                {:else if tasksSummaryLine(section.tasks)}
                  <div class="mt-3">
                    <a
                      href="/tasks"
                      class="text-ink-secondary hover:text-ink-heading text-[12.5px] tabular-nums hover:underline"
                    >
                      {tasksSummaryLine(section.tasks)}
                    </a>
                    {#if section.tasks.top.length > 0}
                      <ul class="divide-paper-hairline mt-1 flex flex-col divide-y">
                        {#each section.tasks.top as item, i (item.id ?? i)}
                          <li class="flex items-baseline gap-2.5 py-2">
                            <span
                              class="border-paper-button-border bg-paper-card size-[13px] shrink-0 self-center rounded-[4px] border"
                              aria-hidden="true"
                            ></span>
                            <a href="/tasks" class="text-ink-body min-w-0 flex-1 text-[13.5px] hover:underline">
                              {item.title ?? '(untitled)'}
                            </a>
                            {#if item.today}
                              <span class="text-act shrink-0 text-[11.5px]">focus</span>
                            {/if}
                            {#if item.due}
                              <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">{item.due}</span>
                            {/if}
                          </li>
                        {/each}
                      </ul>
                    {/if}
                  </div>
                {/if}
              </section>
            {/each}
          </div>
        {/if}

        {#if today.scheduleNotices.length > 0}
          <!-- Notices ONLY for schedules (tasks+schedules spec §Cockpit): a
               parked run, a failed run, a newly registered schedule. No "next
               run" line here — that lives on the Schedules tab, which is also
               where each notice points (the run history under the schedule is
               the access path to a scheduled session's transcript, and the
               notice payload carries no session id). -->
          <section class="mt-8">
            <p class="text-overline mb-2">Schedules</p>
            <ul class="flex flex-col">
              {#each today.scheduleNotices as notice, i (`${notice.mountKey ?? ''}/${notice.scheduleId}/${notice.kind}/${i}`)}
                <li>
                  <a
                    href={scheduleNoticeHref(notice)}
                    class="hover:bg-paper-pill flex items-baseline gap-2 rounded-md py-1.5 pr-2 transition-colors"
                  >
                    <span
                      class={[
                        'size-1.5 shrink-0 self-center rounded-full',
                        notice.kind === 'failed' ? 'bg-warn-ink' : 'bg-act'
                      ]}
                      aria-hidden="true"
                    ></span>
                    <span class="text-ink-body min-w-0 flex-1 text-[13px]">{scheduleNoticeText(notice)}</span>
                    {#if notice.at}
                      <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">
                        {formatTimestamp(notice.at)}
                      </span>
                    {/if}
                  </a>
                </li>
              {/each}
            </ul>
          </section>
        {/if}

        {#if gitAttention.length > 0}
          <!-- Git attention rows (ICM git sync spec §Conflict notices): ONLY
               the three agent-actionable states (diverged, blocked by local
               edits, unfinished merge). Fetch/push/auth failures are
               deliberately absent — those are `error`, which is doctor
               material, not something to interrupt anyone with. Each row's
               button hands the repo to an agent in one click; once a
               resolution session exists it re-reads "Open session", so a
               second resolver never gets started by accident. -->
          <section class="mt-8">
            <p class="text-overline mb-2">Git</p>
            <ul class="flex flex-col">
              {#each gitAttention as repo (repo.mountKey)}
                <li class="py-1.5 pr-2">
                  <div class="flex items-center gap-2">
                    <span class="bg-warn-ink size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                    <span class="text-ink-body min-w-0 flex-1 text-[13px]">{gitAttentionText(repo)}</span>
                    <Button
                      variant="outline"
                      size="sm"
                      disabled={resolving !== null}
                      onclick={() => void resolveConflict(repo)}
                    >
                      {repo.conflictSessionId ? 'Open session' : 'Resolve with agent'}
                    </Button>
                  </div>
                  {#if resolveError[repo.mountKey]}
                    <p class="text-warn-ink mt-1 ml-3.5 text-[12px]" role="alert">
                      {resolveError[repo.mountKey]}
                    </p>
                  {/if}
                </li>
              {/each}
            </ul>
          </section>
        {/if}

        {#if today.recentSessions.length > 0}
          <section class="mt-10 pb-6">
            <p class="text-overline mb-2">Recent sessions</p>
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
      {/if}
    </MainColumn>
  {/snippet}
</AppShell>
