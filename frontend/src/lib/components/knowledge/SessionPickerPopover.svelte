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
    disabledReason = null,
    newSessionRefusal = null,
    openSessionRefusal = null
  }: {
    mountKey: string;
    onOpenSession: (id: string) => void;
    onNewSession: () => void;
    /**
     * Why a NEW session cannot open beside this file, and why an EXISTING one
     * cannot — separately, because they are different descriptor kinds
     * (`chat-new` and `chat`) and `dedupeSurfaces` compares kinds raw. One
     * reason on the trigger cannot answer for both: with a `chat-new` pane
     * already open, "New session" is refused while any recent session is not.
     *
     * That asymmetry is exactly what made this the last silent no-op in the
     * feature. The trigger carried the ROOM refusals — the cap and the width —
     * and nothing carried "already open", so at a wide window with a session
     * pane open the popover opened, the row looked live, and picking it left
     * the URL byte-identical while `dedupeSurfaces` dropped the pane on the way
     * out. Both come from the host's `besideRefusal`, so this control and the
     * row it opens agree by construction.
     */
    newSessionRefusal?: string | null;
    openSessionRefusal?: string | null;
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
    class="refusable text-ink-meta flex size-7 items-center justify-center rounded-md"
  >
    <MessageSquare class="size-4" strokeWidth={1.5} />
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
    <Popover.Content class="max-h-96 w-[248px] overflow-y-auto p-1.5">
      <!-- `aria-disabled` plus a handler guard on the ROW, the same shape every
           other refusal in this feature takes: a truly disabled button takes no
           pointer events, so its reason never appears on hover, and it leaves
           the tab order, so a keyboard user cannot reach it either. The reason
           is also rendered, under the label rather than beside it — these rows
           are 248px and a trailing sentence would either widen the popover or
           be truncated to nothing. -->
      <button
        type="button"
        aria-disabled={newSessionRefusal ? 'true' : undefined}
        title={newSessionRefusal ?? undefined}
        aria-label={newSessionRefusal
          ? `New session — unavailable: ${newSessionRefusal.toLowerCase()}`
          : undefined}
        onclick={() => {
          if (newSessionRefusal) return;
          open = false;
          onNewSession();
        }}
        class="refusable hover:bg-paper-pill text-ink-heading w-full rounded-md px-2 py-1.5 text-left text-[12.5px] [font-weight:650]"
      >
        New session
        {#if newSessionRefusal}
          <span class="text-ink-meta mt-0.5 block text-[10.5px] leading-tight font-normal">
            {newSessionRefusal}
          </span>
        {/if}
      </button>
      {#if sessions.length}
        <p class="text-overline px-2 pt-2 pb-1">Recent</p>
        {#if openSessionRefusal}
          <!-- Once, above the rows, rather than repeated under each of them:
               the reason is a property of the ROW, which is why every row also
               carries it in `title`/`aria-label` and guards its own handler,
               but N copies of one sentence is noise. -->
          <p class="text-ink-meta px-2 pb-1 text-[10.5px] leading-tight">{openSessionRefusal}</p>
        {/if}
        <ul class="flex flex-col">
          {#each sessions as session (session.id)}
            <li>
              <button
                type="button"
                aria-disabled={openSessionRefusal ? 'true' : undefined}
                title={openSessionRefusal ?? undefined}
                aria-label={openSessionRefusal
                  ? `${title(session)} — unavailable: ${openSessionRefusal.toLowerCase()}`
                  : undefined}
                onclick={() => {
                  if (openSessionRefusal) return;
                  open = false;
                  onOpenSession(session.id);
                }}
                class="refusable hover:bg-paper-pill flex w-full items-center gap-1.5 rounded-md px-2 py-1.5 text-left"
              >
                {#if session.live}
                  <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
                {/if}
                <!-- `text-current`, so `refusable`'s colour on the button
                     reaches the label; a `text-ink-*` class here would win
                     against an inherited colour and the row would keep its
                     available ink. -->
                <span
                  class={[
                    'min-w-0 flex-1 truncate text-[12.5px]',
                    openSessionRefusal ? 'text-current' : 'text-ink-secondary'
                  ]}
                >
                  {title(session)}
                </span>
              </button>
            </li>
          {/each}
        </ul>
      {/if}
    </Popover.Content>
  </Popover.Root>
{/if}
