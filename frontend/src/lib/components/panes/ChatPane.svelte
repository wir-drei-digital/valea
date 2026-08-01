<script lang="ts">
  /**
   * A chat surface: the optional all-sessions navigator plus the transcript.
   * The navigator is the route's old `?all=1` column, moved here so a chat in
   * a PANE can have one too. `ChatView` still never reads `page.url` — the
   * descriptor and the callbacks are its whole world, which is the only
   * reason it can be mounted in a pane at all, so the navigator sits BESIDE
   * it rather than inside it.
   *
   * Tolerates no state: a `chat-new` pane has no `createState`, because there
   * is no session to list until it has started — at which point the host
   * rewrites the descriptor to `chat:<id>` and it remounts with both.
   */
  import type { Snippet } from 'svelte';
  import ChatView from '$lib/components/views/ChatView.svelte';
  import Archive from '@lucide/svelte/icons/archive';
  import { api } from '$lib/api/client';
  import { sessionsListStore } from '$lib/stores/sessions-list.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import {
    groupAllSessions,
    sessionRelativeTime,
    sessionTitle
  } from '$lib/components/shell/icm-projects';
  import type { PaneContext } from '$lib/panes/context';
  import type { ChatNewPaneDescriptor, ChatPaneDescriptor } from '$lib/panes/pane-route';
  import type { ChatPaneState } from '$lib/panes/chat-pane-runtime.svelte';

  // Aliased locally because Svelte reads `$state` as a store subscription on
  // a binding called `state`; the prop name the host passes is unchanged.
  let {
    descriptor,
    context,
    state: pane,
    empty
  }: {
    /**
     * `null` only from `/chat` with no `?session=`: the route needs the SAME
     * navigator beside its empty state, since "Show all" lands there with
     * nothing selected and a navigator-less empty state would be a dead end.
     * A pane always has a subject — `PaneHost` mounts this from a descriptor.
     */
    descriptor: ChatPaneDescriptor | ChatNewPaneDescriptor | null;
    context: PaneContext;
    state?: ChatPaneState;
    /** What fills the transcript column when there is no session. */
    empty?: Snippet;
  } = $props();

  // `visibleSessions`, not `sessions`: scheduled runs stay out of this list
  // unless its own toggle asks for them — one hourly schedule would otherwise
  // own the whole column.
  const groups = $derived(groupAllSessions(sessionsListStore.visibleSessions));
  const selectedId = $derived(descriptor?.kind === 'chat' ? descriptor.sessionId : null);

  // --- Archive from a LIST ROW. Live sessions archive too — the backend
  // stops a running session first, then archives — so the row offers the
  // button unconditionally. Archiving the session this pane has OPEN is
  // `ChatView`'s own header affordance; this is the navigator's per-row one,
  // which can reach any session including the open one, hence the handoff to
  // `onArchived` below.
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

    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    // Only when the pane was showing the session that just went: the host
    // decides what "this pane's subject is gone" means (close it, or drop
    // back to the route's own empty state).
    if (selectedId === id) context.onArchived?.();
  }
</script>

<div class="flex min-h-0 min-w-0 flex-1">
  {#if pane?.sessionsVisible}
    <div class="border-paper-hairline w-[240px] shrink-0 overflow-y-auto border-r">
      <!-- "include scheduled runs": scheduled runs are hidden by default —
           they're reached through the run history under their schedule. The
           toggle also re-fetches the NAV feed with `include_scheduled: true`.
           Both stores hold the flag as STATE, because the nav feed is
           refreshed by a dozen callers that know nothing about this checkbox,
           and a one-shot argument let the very next refresh drop scheduled
           runs while the box stayed ticked. -->
      <label class="text-ink-meta flex items-center gap-2 px-3.5 py-2 text-[11.5px]">
        <input
          type="checkbox"
          checked={sessionsListStore.includeScheduled}
          onchange={(event) => {
            const next = event.currentTarget.checked;
            sessionsListStore.includeScheduled = next;
            recentSessionsStore.includeScheduled = next;
            void recentSessionsStore.refresh();
          }}
        />
        Include scheduled runs{sessionsListStore.scheduledCount > 0
          ? ` (${sessionsListStore.scheduledCount})`
          : ''}
      </label>

      {#if groups.length === 0}
        <p class="text-ink-meta px-3.5 py-3 text-[12.5px]">
          {sessionsListStore.sessions.length === 0 ? 'No sessions yet.' : 'No chat sessions yet.'}
        </p>
      {:else}
        {#each groups as group (group.mountKey)}
          <section class="pb-1">
            <p class="text-overline px-3.5 pt-3 pb-1">{group.name}</p>
            <ul class="flex flex-col">
              {#each group.sessions as session (session.id)}
                {@const selected = session.id === selectedId}
                <li class="group/row relative" class:opacity-75={!session.live && !selected}>
                  <!-- A button, not a link: a row inside a pane rewrites THAT
                       pane's descriptor. Following an href would navigate the
                       whole app to `/chat` and throw away whatever this pane
                       was sitting beside. -->
                  <button
                    type="button"
                    onclick={() => context.openPane?.({ kind: 'chat', sessionId: session.id })}
                    aria-current={selected ? 'true' : undefined}
                    class="block w-full border-l-[3px] py-2 pr-9 pl-3.5 text-left transition-colors hover:bg-paper-pill"
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
                      <span class="text-ink-meta shrink-0 text-[11px]">
                        {sessionRelativeTime(session.startedAt)}
                      </span>
                    </span>
                  </button>
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
    </div>
  {/if}
  {#if descriptor}
    <ChatView {descriptor} {context} />
  {:else if empty}
    <div class="min-h-0 flex-1 overflow-y-auto">{@render empty()}</div>
  {/if}
</div>
