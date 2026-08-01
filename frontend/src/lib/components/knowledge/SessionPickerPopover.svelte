<script lang="ts">
  // Mount-scoped session picker (side-panes pass): the reverse-combo entry
  // point — open a recent session (or a new one) beside the file you're
  // reading. Recent list = the same store the sidebar's project groups read
  // (`recentSessionsStore`, refreshed by the root layout on workspace open
  // and by every session create/archive), so this never fetches on its own.
  //
  // Presentational + callback-driven, like `SessionHeader`: it neither reads
  // `page.url` nor navigates — the host route decides that picking a session
  // means "open it in my side pane" (see the knowledge routes' `?pane=`
  // handlers).
  import MessageSquare from '@lucide/svelte/icons/message-square';
  import * as Popover from '$lib/components/ui/popover';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import type { AgentSessionSummary } from '$lib/stores/sessions-list.svelte';

  let {
    mountKey,
    onOpenSession,
    onNewSession,
    disabledReason = null
  }: {
    mountKey: string;
    onOpenSession: (id: string) => void;
    onNewSession: () => void;
    /**
     * Why no session can be opened beside this file right now — the row has no
     * slot left, or the window has no width for one. Every pane this picker
     * opens is a pane the shell's own ＋ Pane would have to allow, and until
     * this existed the two disagreed: at a 900px window ＋ Pane was correctly
     * refusing while this popover, in the header a few pixels above it, opened
     * a chat into a ~130px column with a clipped composer. Shown as the
     * disabled trigger's reason, never as a silent no-op.
     */
    disabledReason?: string | null;
  } = $props();

  let open = $state(false);
  // Server order preserved (live first, then newest) — see the store's doc
  // comment; `[]` for an ICM with no sessions yet.
  const sessions = $derived(recentSessionsStore.sessionsFor(mountKey));

  function title(session: AgentSessionSummary): string {
    if (session.title && session.title.trim().length > 0) return session.title;
    return session.kind === 'workflow' ? 'Workflow run' : 'Chat session';
  }
</script>

{#if disabledReason}
  <!-- A look-alike button rather than a `disabled` trigger, and `aria-disabled`
       rather than `disabled` — the same shape the bar's ＋ Pane takes when it
       has no room. A truly disabled button takes no pointer events, so its
       `title` never appears and the reason is unreachable by mouse; it also
       leaves the tab order, so it is unreachable by keyboard too, and the
       control degrades back into the silent no-op this replaces. -->
  <button
    type="button"
    aria-disabled="true"
    title={disabledReason}
    aria-label={`Open a session beside this file — unavailable: ${disabledReason.toLowerCase()}`}
    onclick={(event) => event.preventDefault()}
    class="text-ink-meta flex size-7 cursor-default items-center justify-center rounded-md"
  >
    <MessageSquare class="size-4 opacity-40" strokeWidth={1.5} />
  </button>
{:else}
  <Popover.Root bind:open>
    <Popover.Trigger
      title="Open a session beside this file"
      aria-label="Open a session beside this file"
      class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-7 items-center justify-center rounded-md transition-colors"
    >
      <MessageSquare class="size-4" strokeWidth={1.5} />
    </Popover.Trigger>
    <!-- `Popover.Content` is `p-0` with no clipping of its own, so the cap and
         the scroll live here — a long session list would otherwise spill past
         the rounded corners. -->
    <Popover.Content class="max-h-96 overflow-y-auto p-1.5">
      <button
        type="button"
        onclick={() => {
          open = false;
          onNewSession();
        }}
        class="hover:bg-paper-pill text-ink-heading w-full rounded-md px-2 py-1.5 text-left text-[12.5px] [font-weight:650]"
      >
        New session
      </button>
      {#if sessions.length}
        <p class="text-overline px-2 pt-2 pb-1">Recent</p>
        <ul class="flex flex-col">
          {#each sessions as session (session.id)}
            <li>
              <button
                type="button"
                onclick={() => {
                  open = false;
                  onOpenSession(session.id);
                }}
                class="hover:bg-paper-pill flex w-full items-center gap-1.5 rounded-md px-2 py-1.5 text-left"
              >
                {#if session.live}
                  <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                {/if}
                <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12.5px]">{title(session)}</span>
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    </Popover.Content>
  </Popover.Root>
{/if}
