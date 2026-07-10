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
  import { SessionsListStore, type AgentSessionSummary } from '$lib/stores/sessions-list.svelte';
  import { AgentSessionStore } from '$lib/stores/agent-session.svelte';
  import { Transcript, PlanBar, UsageLine, Composer, DoctorPanel } from '$lib/components/agent';

  const sessionsList = new SessionsListStore(api);

  onMount(() => {
    void sessionsList.refresh();
  });

  const selectedId = $derived(page.url.searchParams.get('session'));

  // True whenever the most recent "start a session" attempt (from either the
  // list footer or the empty state) hit `harness_unavailable`, or the user
  // followed the empty state's quiet "Run checks" link — shown in place of
  // whatever the main pane would otherwise render, regardless of whether a
  // session id is currently selected. Reset by the selection effect below
  // whenever the selected id actually changes (a fresh session was created,
  // or the user picked a different one from the list).
  let doctorOverride = $state(false);

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

  async function startSession(): Promise<void> {
    const result = await api.createAgentSession('chat', workspaceStore.generation ?? 0);
    if (result.ok) {
      const data = result.data as { id: string };
      doctorOverride = false;
      await sessionsList.refresh();
      void goto(`/chat?session=${data.id}`);
    } else if (result.error === 'harness_unavailable') {
      doctorOverride = true;
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
    if (session.kind === 'workflow') return session.workflow ?? 'Workflow run';
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
  const sessionDoctor = $derived.by(
    () => store !== null && store.status === 'failed' && store.error === 'harness_unavailable'
  );

  async function startFollowUp(): Promise<void> {
    await startSession();
  }
</script>

<AppFrame>
  {#snippet list()}
    <ListPane>
      {#snippet header()}
        <p class="text-overline">Chat</p>
      {/snippet}
      {#snippet children()}
        <ul class="flex flex-col py-1">
          {#each sortedSessions(sessionsList.sessions) as session (session.id)}
            <li class:opacity-75={!session.live}>
              <a
                href={`/chat?session=${session.id}`}
                class="flex items-center gap-2 py-2 pr-3 pl-3 text-[13px] text-ink-body transition-colors hover:bg-paper-pill"
                class:bg-paper-card={session.id === selectedId}
              >
                <span
                  class="size-1.5 shrink-0 rounded-full"
                  class:bg-act-dot={session.live}
                  aria-hidden="true"
                ></span>
                <span class="min-w-0 flex-1 truncate">{sessionTitle(session)}</span>
                {#if session.kind === 'workflow' && session.workflow}
                  <span
                    class="border-paper-chip-border bg-paper-card shrink-0 rounded-sm border px-1.5 py-px font-mono text-[10px] text-ink-secondary"
                  >
                    {session.workflow}
                  </span>
                {/if}
                <span class="text-ink-meta shrink-0 text-[11px]">{relativeTime(session.startedAt)}</span>
              </a>
            </li>
          {/each}
        </ul>
      {/snippet}
      {#snippet footer()}
        <Button
          type="button"
          variant="outline"
          size="sm"
          class="w-full"
          onclick={() => void startSession()}
        >
          New session
        </Button>
      {/snippet}
    </ListPane>
  {/snippet}

  {#snippet main()}
    {#if doctorOverride}
      <DoctorPanel />
    {:else if !selectedId}
      <EmptyState
        icon={MessageSquare}
        title="Talk to your assistant"
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
        {/snippet}
      </EmptyState>
    {:else if sessionDoctor}
      <DoctorPanel />
    {:else if store}
      <div class="flex flex-col gap-3">
        <PlanBar item={planItem} />

        <Transcript {store} />

        <UsageLine item={usageItem} />

        {#if starting}
          <p class="text-ink-meta px-4 py-3 text-[12.5px]">Starting…</p>
        {:else if ended}
          <div class="border-paper-hairline flex items-center justify-between border-t px-4 py-3">
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
      <p class="text-ink-meta text-[13px]">Loading…</p>
    {/if}
  {/snippet}
</AppFrame>
