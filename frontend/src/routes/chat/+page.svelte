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
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveIcmSelection } from '$lib/shell/icm-route';
  import { SessionsListStore, type AgentSessionSummary } from '$lib/stores/sessions-list.svelte';
  import { AgentSessionStore } from '$lib/stores/agent-session.svelte';
  import { Transcript, PlanBar, UsageLine, Composer, DoctorPanel } from '$lib/components/agent';

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
    const session = new AgentSessionStore(id);
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

  async function startSession(): Promise<void> {
    startError = null;
    const mountKey = primaryMountKey();
    if (!mountKey) {
      startError = 'No ICM is mounted yet. Add one in Knowledge first.';
      return;
    }
    const result = await api.createAgentSession('chat', mountKey, workspaceStore.generation ?? 0);
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

  function sortedSessions(sessions: AgentSessionSummary[]): AgentSessionSummary[] {
    // Live sessions first, then ended — most recently started first within
    // each group.
    return [...sessions].sort((a, b) => {
      if (a.live !== b.live) return a.live ? -1 : 1;
      return (b.startedAt ?? '').localeCompare(a.startedAt ?? '');
    });
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
  const configItems = $derived.by(() => store?.items.filter((item) => item.type === 'config') ?? []);

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

  async function startFollowUp(): Promise<void> {
    await startSession();
  }
</script>

<AppFrame mainVariant="column">
  {#snippet list()}
    <ListPane title="Chat">
      {#snippet action()}
        <Button type="button" variant="outline" size="sm" onclick={() => void startSession()}>
          New session
        </Button>
      {/snippet}
      {#snippet children()}
        <ul class="divide-paper-hairline flex flex-col divide-y">
          {#each sortedSessions(sessionsList.sessions) as session (session.id)}
            {@const selected = session.id === selectedId}
            <li class:opacity-75={!session.live}>
              <a
                href={`/chat?session=${session.id}`}
                class="block border-l-[3px] py-3 pr-4 pl-3.5 transition-colors hover:bg-paper-pill"
                class:border-act={selected}
                class:border-transparent={!selected}
                class:bg-paper-card={selected}
              >
                <span class="flex items-baseline justify-between gap-3">
                  <span class="flex min-w-0 items-center gap-1.5">
                    {#if session.live}
                      <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                    {/if}
                    <span class="text-ink-heading truncate text-[13.5px] [font-weight:650]">
                      {sessionTitle(session)}
                    </span>
                  </span>
                  <span class="text-ink-meta shrink-0 text-[11.5px]">{relativeTime(session.startedAt)}</span>
                </span>
                {#if session.kind === 'workflow' && session.workflow}
                  <span class="text-ink-meta mt-1 block truncate font-mono text-[10.5px]">
                    {session.workflow}
                  </span>
                {/if}
              </a>
            </li>
          {/each}
        </ul>
      {/snippet}
    </ListPane>
  {/snippet}

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
          body="Talk to your assistant about the business — everything it knows is a file in your folder."
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
        <PlanBar item={planItem} />

        <div class="min-h-0 flex-1 overflow-y-auto">
          <Transcript {store} />
        </div>

        <UsageLine item={usageItem} />

        {#if starting}
          <p class="text-ink-meta px-4 py-4 text-[12.5px]">Starting…</p>
        {:else if ended}
          <div class="border-paper-hairline mx-4 mb-4 flex items-center justify-between gap-3 border-t px-0 pt-3">
            <p class="text-ink-meta text-[12.5px]">This session has ended.</p>
            <Button type="button" variant="outline" size="sm" onclick={() => void startFollowUp()}>
              Start a follow-up session
            </Button>
          </div>
        {:else}
          <Composer
            busy={store.busy}
            {configItems}
            onSend={(text) => store?.prompt(text)}
            onStop={() => store?.cancel()}
            onSetConfig={(configId, value) => store?.setConfigOption(configId, value)}
          />
        {/if}
      </div>
    {:else}
      <p class="text-ink-meta px-8 py-8 text-[13px]">Loading…</p>
    {/if}
  {/snippet}
</AppFrame>
