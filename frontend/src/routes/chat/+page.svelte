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
  import Archive from '@lucide/svelte/icons/archive';
  import { groupAllSessions } from '$lib/components/shell/icm-projects';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveIcmSelection } from '$lib/shell/icm-route';
  import { sessionsListStore, type AgentSessionSummary } from '$lib/stores/sessions-list.svelte';
  import { DoctorPanel } from '$lib/components/agent';
  import ChatView from '$lib/components/views/ChatView.svelte';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import { parsePaneParam, withPaneParam, promoteHref, type PaneDescriptor } from '$lib/panes/pane-route';

  // The open transcript lives in `ChatView` (side-panes pass) — everything
  // below is the ROUTE's own business: which session is selected (`?session=`),
  // the optional all-sessions list pane (`?all=1`), starting a session, and
  // the doctor fallback. The flat session list is the MODULE SINGLETON now
  // (it used to be a route-local `new SessionsListStore(api)`), so the list
  // pane here and the `ChatView`(s) mounted by this route — or, from Task 8,
  // by a side pane — all read and refresh ONE list.

  onMount(() => {
    void sessionsListStore.refresh();
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
  const allGroups = $derived(groupAllSessions(sessionsListStore.sessions));

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

  // A fresh selection clears the doctor override — a new session was created,
  // or the user picked a different one from the list. Stays here (not in
  // `ChatView`): the override replaces whatever the MAIN PANE would render,
  // selected session or not, so it's the route's state, not a view's.
  $effect(() => {
    void selectedId;
    doctorOverride = false;
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
      await sessionsListStore.refresh();
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

  // --- Archive from a LIST ROW (ended sessions only — the backend refuses a
  // live one). Archiving the session that's currently OPEN is `ChatView`'s
  // own affordance (its header) with its own in-flight/error state; this
  // path is the all-sessions pane's per-row button, which can archive any
  // session, including the open one — hence the navigation below.

  let archiving: Record<string, boolean> = $state({});
  let archiveError = $state<string | null>(null);

  async function archiveSession(id: string): Promise<void> {
    archiveError = null;
    archiving = { ...archiving, [id]: true };
    const result = await api.archiveAgentSession(id, workspaceStore.generation ?? 0);
    archiving = { ...archiving, [id]: false };

    if (!result.ok) {
      archiveError =
        result.error === 'session_live'
          ? 'This session is still running — stop it before archiving.'
          : 'Could not archive the session. Please try again.';
      return;
    }

    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    if (selectedId === id) {
      void goto(showAllPane ? '/chat?all=1' : '/chat');
    }
  }

  /** Where the main pane goes once `ChatView` archives the session it has open. */
  function afterArchive(): void {
    void goto(showAllPane ? '/chat?all=1' : '/chat');
  }

  // --- Side pane (`?pane=`) ---
  //
  // The URL is the ONE source of truth for what's open beside the chat, so a
  // split view is linkable, survives reload, and the back button closes the
  // pane. `parsePaneParam` fails closed (invalid → null → primary alone), and
  // `PaneHost` additionally drops a pane that duplicates the primary view.
  // Every navigation below keeps focus and scroll: opening a file from a tool
  // chip mid-stream must not yank the transcript or blur the composer.
  const paneDescriptor = $derived(parsePaneParam(page.url.searchParams.get('pane')));
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    selectedId ? { kind: 'chat', sessionId: selectedId } : null
  );

  /** Tool chips and the session header's file tree both land here. */
  function openFilePane(sel: { mountKey: string; path: string }): void {
    void goto(withPaneParam(page.url, { kind: 'file', ...sel }), { keepFocus: true, noScroll: true });
  }

  function closePane(): void {
    void goto(withPaneParam(page.url, null), { keepFocus: true, noScroll: true });
  }

  // `chat:new:<mount>` has no entry point on this route today (Knowledge owns
  // that one — Task 9), but the registry maps the kind, so a hand-written or
  // shared URL can mount it here. Wiring the rewrite is what keeps the first
  // typed message alive: the composer clears on send, and the view hands the
  // created id back expecting its host to re-point it at `chat:<id>` so the
  // stashed prompt actually fires.
  function replacePaneWithSession(id: string): void {
    void goto(withPaneParam(page.url, { kind: 'chat', sessionId: id }), {
      keepFocus: true,
      noScroll: true
    });
  }

  /** "Open as full view" — the pane's subject becomes a route of its own. */
  function promotePane(d: PaneDescriptor): void {
    void goto(promoteHref(d));
  }
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
                  {#if !session.live}
                    <button
                      type="button"
                      aria-label={`Archive ${sessionTitle(session)}`}
                      title="Archive"
                      disabled={!!archiving[session.id]}
                      onclick={() => void archiveSession(session.id)}
                      class="text-ink-meta hover:text-ink-heading hover:bg-paper-card absolute top-1/2 right-1.5 flex size-6 -translate-y-1/2 items-center justify-center rounded-md opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 focus-visible:opacity-100"
                    >
                      <Archive class="size-3.5" strokeWidth={1.5} />
                    </button>
                  {/if}
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

<AppFrame list={showAllPane ? allSessions : undefined}>
  {#snippet main()}
    <!-- The doctor override deliberately sits OUTSIDE `PaneHost`: it replaces
         the whole main pane (it's the "the assistant isn't wired up" screen),
         so splitting it next to a file would be nonsense. `?pane=` survives
         in the URL, so dismissing the override restores the split. -->
    {#if doctorOverride}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
        <DoctorPanel />
      </div>
    {:else}
      <PaneHost
        {primaryDescriptor}
        pane={paneDescriptor}
        paneContext={{
          placement: 'pane',
          sessionCreated: replacePaneWithSession,
          onArchived: closePane
        }}
        onClose={closePane}
        onPromote={promotePane}
      >
        {#snippet primary()}
          {#if !selectedId}
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
          {:else}
            <ChatView
              descriptor={{ kind: 'chat', sessionId: selectedId }}
              context={{ placement: 'primary', openFile: openFilePane, onArchived: afterArchive }}
            />
          {/if}
        {/snippet}
      </PaneHost>
    {/if}
  {/snippet}
</AppFrame>
