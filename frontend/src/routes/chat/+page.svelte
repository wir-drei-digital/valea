<script lang="ts">
  // Chat route (spec Task 18): sessions list + live transcript + composer,
  // with a doctor fallback when the agent harness isn't ready. Composed the
  // same way as `/knowledge` (AppFrame + ListPane), but the main pane's
  // content is driven by the `?session=<id>` query param rather than a path
  // segment, since sessions aren't part of the ICM file tree.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';
  import { AppFrame, ListPane, EmptyState } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import MessageSquare from '@lucide/svelte/icons/message-square';
  import Folder from '@lucide/svelte/icons/folder';
  import Archive from '@lucide/svelte/icons/archive';
  import { groupAllSessions } from '$lib/components/shell/icm-projects';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveIcmSelection } from '$lib/shell/icm-route';
  import { SessionsListStore, type AgentSessionSummary } from '$lib/stores/sessions-list.svelte';
  import { AgentSessionStore } from '$lib/stores/agent-session.svelte';
  import { takeInitialPrompt } from '$lib/stores/initial-prompt';
  import { Transcript, PlanBar, Composer, DoctorPanel } from '$lib/components/agent';
  import { sessionInfoTitle } from '$lib/components/agent/item-shapes';

  const sessionsList = new SessionsListStore(api);

  onMount(() => {
    void sessionsList.refresh();
    // `mountsStore` has no other consumer before this page unless Knowledge
    // was already visited this session (it's a shared singleton — see
    // `mounts.svelte.ts`) — `startSession` needs `mounts` populated to pick
    // a primary ICM, so refresh it here too.
    void mountsStore.refresh();
  });

  // Task 9.4 formalizes the `?icm` / `?session` route scheme: `?icm=<key>`
  // ONLY ever selects the ICM for a brand-new session (`resolveIcmSelection`,
  // shared with Knowledge's identical default — see `icm-route.ts`),
  // falling back to the first enabled, non-degraded mount (config order)
  // when absent. `primaryMountKey` is only ever called from `startSession`
  // — i.e. only when CREATING a session (the empty state's "Start a
  // session", the list pane's "New session", and "Start a follow-up
  // session") — so it deliberately never looks at `?session=`: a currently
  // open transcript (whatever `selectedId`/`store` below are showing) is
  // never reassigned by either query param; starting a new session is a
  // wholly independent action from whatever happens to already be open.
  function primaryMountKey(): string | null {
    const enabledMountKeys = mountsStore.mounts.filter((m) => m.enabled && !m.degraded).map((m) => m.mountKey);
    return resolveIcmSelection(page.url.searchParams.get('icm'), enabledMountKeys);
  }

  // Authoritative for the open transcript (Task 9.4) — driven ENTIRELY by
  // `?session=`; `?icm=` is never consulted here, so it can never reassign
  // which session's channel this page joins.
  const selectedId = $derived(page.url.searchParams.get('session'));

  // `?all=1` opens the all-sessions pane (the sidebar's "Show all" row) —
  // by default the chat route renders WITHOUT a list pane, since the main
  // nav's project groups already carry the recent sessions.
  const showAllPane = $derived(page.url.searchParams.get('all') === '1');
  const allGroups = $derived(groupAllSessions(sessionsList.sessions));

  /** Keeps ?all=1 sticky across in-pane navigation. */
  function sessionHref(id: string): string {
    return showAllPane ? `/chat?all=1&session=${id}` : `/chat?session=${id}`;
  }

  // True whenever the most recent "start a session" attempt (from either the
  // list footer or the empty state) hit `harness_unavailable`, or the user
  // followed the empty state's quiet "Run checks" link — shown in place of
  // whatever the main pane would otherwise render, regardless of whether a
  // session id is currently selected. Reset by the selection effect below
  // whenever the selected id actually changes (a fresh session was created,
  // or the user picked a different one from the list).
  let doctorOverride = $state(false);
  let startError = $state<string | null>(null);

  let store: AgentSessionStore | null = $state(null);

  $effect(() => {
    const id = selectedId;
    doctorOverride = false;
    if (!id) {
      store = null;
      return;
    }
    // `takeInitialPrompt` consumes the one-shot handoff (`initial-prompt.ts`)
    // stashed by a session entry point (e.g. Knowledge's "Start a session
    // with this page") right before it navigated here — the store fires it
    // as the first user turn once its channel join succeeds. A plain
    // sessions-list click or a reload finds nothing pending, which is safe.
    const session = new AgentSessionStore(id, { initialPrompt: takeInitialPrompt(id) });
    store = session;
    return () => {
      session.dispose();
    };
  });

  // Task 9.3's KNOWN GAP, closed here (frontend-only, sanctioned — see the
  // brief): there is no workspace-level "a session's status changed"
  // broadcast (`recent-sessions.svelte.ts`'s `wireRecentSessionsEvents` doc
  // comment explains why — `SessionServer`'s status push only rides the
  // per-session `agent_session:<id>` topic this page already joins, never
  // the shared `workspace:events` join `recentSessionsStore` listens on).
  // So: observe the OPEN session's own `status` here (the one place this
  // page already has a live per-session subscription) and refresh the
  // sidebar's project groups whenever it actually TRANSITIONS — an ended/
  // failed/exited session elsewhere would otherwise show as live in the
  // sidebar until some unrelated `mounts_changed` push happened to refresh
  // it. Deliberately only-on-transition, not on every render: switching
  // `store` to a DIFFERENT (or no) session resets tracking without firing —
  // that session's own creation/selection already triggered whatever
  // refresh it needed (`IcmProjects.svelte`'s `startSession` refreshes
  // right after `createAgentSession` succeeds), so re-observing its
  // starting status here would be a redundant, not a missing, refresh.
  let statusEffectStore: AgentSessionStore | null = null;
  let previousStatus: string | null = null;

  $effect(() => {
    const current = store;
    const status = current?.status ?? null;

    if (current !== statusEffectStore) {
      statusEffectStore = current;
      previousStatus = status;
      return;
    }

    if (status !== previousStatus) {
      previousStatus = status;
      void recentSessionsStore.refresh();
    }
  });

  // Same pattern as the status effect above, for the session's TITLE: the
  // agent pushes its own session title over ACP (`session_info` item,
  // protocol-level — any ACP agent), and the backend persists it into the
  // transcript meta every session listing reads. A transition in the OPEN
  // session's live title is the one signal this page can observe, so it
  // re-fetches both its own list pane and the sidebar's project groups.
  // Only-on-transition, and only when a real title appeared — switching to a
  // session that already has one resets tracking without firing (its list
  // rows are already correct), and a title-less `session_info` upsert
  // (undefined) never triggers a refresh.
  const liveTitle = $derived.by(() => (store ? sessionInfoTitle(store.items) : undefined));

  let titleEffectStore: AgentSessionStore | null = null;
  let previousTitle: string | undefined = undefined;

  $effect(() => {
    const current = store;
    const title = liveTitle;

    if (current !== titleEffectStore) {
      titleEffectStore = current;
      previousTitle = title;
      return;
    }

    if (title !== previousTitle) {
      previousTitle = title;
      if (title) {
        void sessionsList.refresh();
        void recentSessionsStore.refresh();
      }
    }
  });

  async function startSession(): Promise<void> {
    startError = null;
    const mountKey = primaryMountKey();
    if (!mountKey) {
      startError = 'No ICM is mounted yet. Add one in Knowledge first.';
      return;
    }
    const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0);
    if (result.ok) {
      const data = result.data as { id: string };
      doctorOverride = false;
      await sessionsList.refresh();
      void goto(`/chat?session=${data.id}`);
    } else if (result.error === 'harness_unavailable') {
      doctorOverride = true;
    } else {
      // Any other failure (workspace_not_open, workspace_changed,
      // icm_unavailable, …) — surface it calmly instead of a silent no-op
      // on the button.
      startError = errorMessage(result.error);
    }
  }

  function errorMessage(code: string): string {
    switch (code) {
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'workspace_not_open':
        return 'No workspace is open.';
      case 'icm_unavailable':
        return "That ICM isn't available. Enable it in Knowledge and try again.";
      default:
        return 'The session could not be started. Please try again.';
    }
  }

  function sessionTitle(session: AgentSessionSummary): string {
    if (session.title && session.title.trim().length > 0) return session.title;
    // Untitled workflow runs show a plain title here — the workflow's file
    // path renders as its own mono line under the title, so repeating it as
    // the title would double it up.
    if (session.kind === 'workflow') return 'Workflow run';
    return 'Chat session';
  }

  function relativeTime(iso: string | null | undefined): string {
    if (!iso) return '';
    const date = new Date(iso);
    if (Number.isNaN(date.getTime())) return '';
    const rtf = new Intl.RelativeTimeFormat('en', { numeric: 'auto' });
    const deltaSeconds = Math.round((date.getTime() - Date.now()) / 1000);
    const abs = Math.abs(deltaSeconds);
    if (abs < 60) return rtf.format(deltaSeconds, 'second');
    if (abs < 3600) return rtf.format(Math.round(deltaSeconds / 60), 'minute');
    if (abs < 86400) return rtf.format(Math.round(deltaSeconds / 3600), 'hour');
    return rtf.format(Math.round(deltaSeconds / 86400), 'day');
  }

  // Dock singletons (see Transcript.svelte's doc comment) — derived from the
  // same `store.items` the transcript itself reads. `plan`/`usage` items are
  // updated in place by the backend (same id re-upserted), so the latest one
  // by seq order is the live one; `config` items are a flat set (e.g.
  // permission mode + model), so those are filtered, not reduced to one.
  const planItem = $derived.by(() => store?.items.findLast((item) => item.type === 'plan'));
  const usageItem = $derived.by(() => store?.items.findLast((item) => item.type === 'usage'));
  // Sorted by id, not timeline order: `set_config_option` re-emits config
  // items (fresh seq), which would otherwise shuffle the chips under the
  // composer every time an option changes.
  const configItems = $derived.by(() =>
    (store?.items.filter((item) => item.type === 'config') ?? []).sort((a, b) =>
      a.id.localeCompare(b.id)
    )
  );

  // Which ICM the OPEN session runs in ("in the chat session, it is not
  // clear for which ICM the current session is active"). The summary's own
  // `icmName` (session/v1 metadata, threaded through `trim_summary/1`) is
  // authoritative; the recent-sessions groups are the fallback while the
  // flat list is still loading (a freshly created session reaches this page
  // right after `sessionsList.refresh()`, so the gap is brief).
  const openSessionIcmName = $derived.by(() => {
    if (!selectedId) return null;
    const summary = sessionsList.sessions.find((s) => s.id === selectedId);
    if (summary?.icmName) return summary.icmName;
    for (const group of recentSessionsStore.groups) {
      if (group.sessions.some((s) => s.id === selectedId)) return group.icmName;
    }
    return null;
  });

  const ended = $derived.by(
    () =>
      store !== null &&
      (store.status === 'ended' || store.status === 'exited' || store.status === 'failed')
  );
  const starting = $derived.by(
    () => store !== null && (store.status === 'connecting' || store.status === 'starting')
  );
  // Defensive only: harness_unavailable surfaces synchronously at session
  // creation (see startSession), so a joined session cannot currently reach
  // this state — kept as a guard in case that resolution ever moves post-join.
  const sessionDoctor = $derived.by(
    () => store !== null && store.status === 'failed' && store.error === 'harness_unavailable'
  );

  // --- Same-transcript resume: sending into an ENDED session revives it
  // in place (same id, same transcript, same URL) and then delivers the
  // prompt — "continue", never a confusing new session. The RPC only
  // returns ok once the revived server is registered, so the immediate
  // prompt push routes to it (the channel re-checks the Registry).

  let resuming = $state(false);
  let resumeError = $state<string | null>(null);

  async function resumeAndPrompt(text: string): Promise<void> {
    const id = selectedId;
    const session = store;
    if (!id || !session || resuming) return;
    resuming = true;
    resumeError = null;
    const result = await api.resumeAgentSession(id, workspaceStore.generation ?? 0);
    resuming = false;
    if (!result.ok) {
      resumeError = resumeErrorMessage(result.error);
      return;
    }
    session.prompt(text);
    void sessionsList.refresh();
    void recentSessionsStore.refresh();
  }

  function resumeErrorMessage(code: string): string {
    switch (code) {
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'icm_unavailable':
        return "This session's project isn't available. Enable it in the sidebar and try again.";
      case 'harness_unavailable':
        return "The assistant isn't ready — open Agent settings (the gear in the sidebar) and run the checks.";
      case 'not_found':
        return 'This session is no longer on disk.';
      default:
        return 'Could not continue the session. Please try again.';
    }
  }

  // --- Archive (live sessions are stopped first by the backend) ---

  let archiving: Record<string, boolean> = $state({});
  let archiveError = $state<string | null>(null);

  async function archiveSession(id: string): Promise<void> {
    archiveError = null;
    archiving = { ...archiving, [id]: true };
    const result = await api.archiveAgentSession(id, workspaceStore.generation ?? 0);
    archiving = { ...archiving, [id]: false };

    if (!result.ok) {
      archiveError = 'Could not archive the session. Please try again.';
      return;
    }

    void sessionsList.refresh();
    void recentSessionsStore.refresh();
    if (selectedId === id) {
      void goto(showAllPane ? '/chat?all=1' : '/chat');
    }
  }

  // --- Stick-to-bottom auto-scroll while a reply streams in ---
  //
  // `pinned` tracks whether the user is (near) the bottom; any timeline
  // change scrolls back down ONLY while pinned, so reading older content
  // mid-stream is never yanked away. Deliberately a plain variable, not
  // $state — the effect must re-run on `store.items` changes, never on
  // scroll-position changes.
  let scroller = $state<HTMLDivElement | null>(null);
  let pinned = true;

  function onTranscriptScroll(): void {
    const el = scroller;
    if (!el) return;
    pinned = el.scrollHeight - el.scrollTop - el.clientHeight < 96;
  }

  $effect(() => {
    void store?.items;
    const el = scroller;
    if (!el || !pinned) return;
    el.scrollTop = el.scrollHeight;
  });

  // Opening a different session always starts pinned at the newest content.
  $effect(() => {
    void selectedId;
    pinned = true;
  });
</script>

<!-- The all-sessions pane (sidebar "Show all", `?all=1`): EVERY session,
     grouped by project, most recently active first — the default chat
     route renders with NO list pane, since the main nav's project groups
     already carry the recent sessions. -->
{#snippet allSessions()}
  <ListPane title="All sessions">
    {#snippet action()}
      <Button type="button" variant="outline" size="sm" onclick={() => void startSession()}>
        New session
      </Button>
    {/snippet}
    {#snippet children()}
      {#if allGroups.length === 0}
        <p class="text-ink-meta px-3.5 py-3 text-[12.5px]">No sessions yet.</p>
      {:else}
        {#each allGroups as group (group.mountKey)}
          <section class="pb-1">
            <p class="text-overline px-3.5 pt-3 pb-1">{group.name}</p>
            <ul class="flex flex-col">
              {#each group.sessions as session (session.id)}
                {@const selected = session.id === selectedId}
                <li class="group/row relative" class:opacity-75={!session.live && !selected}>
                  <a
                    href={sessionHref(session.id)}
                    class="block border-l-[3px] py-2 pr-9 pl-3.5 transition-colors hover:bg-paper-pill"
                    class:border-act={selected}
                    class:border-transparent={!selected}
                    class:bg-paper-card={selected}
                  >
                    <span class="flex items-baseline justify-between gap-3">
                      <span class="flex min-w-0 items-center gap-1.5">
                        {#if session.live}
                          <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                        {/if}
                        <span class="text-ink-heading truncate text-[13px] [font-weight:650]">
                          {sessionTitle(session)}
                        </span>
                      </span>
                      <span class="text-ink-meta shrink-0 text-[11px]">{relativeTime(session.startedAt)}</span>
                    </span>
                  </a>
                  <button
                    type="button"
                    aria-label={`Archive ${sessionTitle(session)}`}
                    title={session.live ? 'Stop & archive' : 'Archive'}
                    disabled={!!archiving[session.id]}
                    onclick={() => void archiveSession(session.id)}
                    class="text-ink-meta hover:text-ink-heading hover:bg-paper-card absolute top-1/2 right-1.5 flex size-6 -translate-y-1/2 items-center justify-center rounded-md opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 focus-visible:opacity-100"
                  >
                    <Archive class="size-3.5" strokeWidth={1.5} />
                  </button>
                </li>
              {/each}
            </ul>
          </section>
        {/each}
      {/if}
      {#if archiveError}
        <p class="text-warn-ink px-3.5 py-1 text-[11.5px]" role="alert">{archiveError}</p>
      {/if}
    {/snippet}
  </ListPane>
{/snippet}

<AppFrame mainVariant="column" list={showAllPane ? allSessions : undefined}>
  {#snippet main()}
    {#if doctorOverride}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
        <DoctorPanel />
      </div>
    {:else if !selectedId}
      <div class="mx-auto w-full max-w-[660px] px-8 py-8">
        <EmptyState
          icon={MessageSquare}
          title="Your assistant"
          body="Talk to your assistant about the business. Everything it knows is a file in your folder."
        >
          {#snippet actions()}
            <Button type="button" onclick={() => void startSession()}>Start a session</Button>
            <button
              type="button"
              class="text-ink-secondary hover:text-ink-heading text-[12.5px]"
              onclick={() => (doctorOverride = true)}
            >
              Run checks
            </button>
            {#if startError}
              <p class="text-warn-ink text-[12.5px]" role="alert">{startError}</p>
            {/if}
          {/snippet}
        </EmptyState>
      </div>
    {:else if sessionDoctor}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
        <DoctorPanel />
      </div>
    {:else if store}
      <!-- Transcript scrolls; the composer (or the ended/starting row) stays
           docked at the pane's bottom edge, per the cockpit chat screen. -->
      <div class="mx-auto flex min-h-0 w-full max-w-[660px] flex-1 flex-col px-4 pt-3">
        {#if openSessionIcmName || selectedId}
          <div class="border-paper-hairline flex items-center gap-1.5 border-b px-4 pb-2">
            {#if openSessionIcmName}
              <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
              <span class="text-ink-meta text-[12px]">
                Working in <span class="text-ink-secondary font-medium">{openSessionIcmName}</span>
              </span>
            {/if}
            <span class="min-w-0 flex-1" aria-hidden="true"></span>
            {#if selectedId}
              <!-- Live sessions archive too — the backend stops them first. -->
              <button
                type="button"
                onclick={() => selectedId && void archiveSession(selectedId)}
                disabled={!!archiving[selectedId]}
                class="text-ink-meta hover:text-ink-heading flex shrink-0 items-center gap-1 text-[12px] transition-colors"
              >
                <Archive class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
                {archiving[selectedId] ? 'Archiving…' : ended ? 'Archive' : 'Stop & archive'}
              </button>
            {/if}
          </div>
          {#if archiveError && !showAllPane}
            <p class="text-warn-ink px-4 pt-1 text-[11.5px]" role="alert">{archiveError}</p>
          {/if}
        {/if}
        <PlanBar item={planItem} />

        <div bind:this={scroller} onscroll={onTranscriptScroll} class="min-h-0 flex-1 overflow-y-auto">
          <Transcript {store} />
        </div>

        {#if starting}
          <p class="text-ink-meta px-4 py-4 text-[12.5px]">Starting…</p>
        {:else}
          {#if resumeError}
            <p class="text-warn-ink px-4 pt-2 text-[12px]" role="alert">{resumeError}</p>
          {/if}
          <!-- An ended session keeps its composer: sending resumes it in
               place (same transcript) and delivers the message — the
               placeholder carries the affordance, no extra button. A LIVE
               session's send is queue-aware (`store.send`): mid-turn
               messages wait in the composer's queue until the turn ends. -->
          <Composer
            busy={store.busy || resuming}
            {configItems}
            {usageItem}
            queued={store.queued}
            turnStartedAt={store.turnStartedAt}
            placeholder={ended ? 'Continue this session…' : 'Message the agent…'}
            onSend={(text) => (ended ? void resumeAndPrompt(text) : store?.send(text))}
            onStop={() => store?.cancel()}
            onSetConfig={(configId, value) => store?.setConfigOption(configId, value)}
            onEditQueued={(id, text) => store?.updateQueued(id, text)}
            onDismissQueued={(id) => store?.dismissQueued(id)}
            onSendQueuedNow={(id) => store?.sendQueuedNow(id)}
          />
        {/if}
      </div>
    {:else}
      <p class="text-ink-meta px-8 py-8 text-[13px]">Loading…</p>
    {/if}
  {/snippet}
</AppFrame>
