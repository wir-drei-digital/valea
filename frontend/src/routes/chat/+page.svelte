<script lang="ts">
  // Chat route: the transcript and its optional all-sessions navigator are
  // ONE surface now — `ChatPane` — and this route renders it as its primary
  // pane, with `?pane=` panes beside it. Everything that used to be the
  // shell's `list` column (grouping, per-row archive, the include-scheduled
  // toggle) moved into that component, so a chat mounted in a PANE has a
  // navigator too.
  //
  // What is left here is the ROUTE's own business: which session is selected
  // (`?session=`), whether the navigator shows (`?all=1`), starting a
  // session, and the doctor fallback.
  import { page } from '$app/state';
  import { goto } from '$app/navigation';
  import { onMount } from 'svelte';
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import MessageSquare from '@lucide/svelte/icons/message-square';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { sessionsListStore } from '$lib/stores/sessions-list.svelte';
  import { resolveIcmSelection } from '$lib/shell/icm-route';
  import { DoctorPanel } from '$lib/components/agent';
  import ChatPane from '$lib/components/panes/ChatPane.svelte';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import { ChatPaneState } from '$lib/panes/chat-pane-runtime.svelte';
  import {
    chatNavigatorFromUrl,
    chatNewParam,
    dedupeSurfaces,
    hrefWithPanes,
    parsePaneParam,
    parsePanes,
    type PaneDescriptor
  } from '$lib/panes/pane-route';
  import { paneWiring } from '$lib/panes/pane-wiring';
  import { paneRoom } from '$lib/shell/pane-room.svelte';
  import { watchPaneMemory } from '$lib/panes/pane-memory.svelte';
  import type { PaneContext } from '$lib/panes/context';

  onMount(() => {
    // The flat session list is a MODULE SINGLETON, read by the navigator in
    // every mounted `ChatPane` — the primary's and any pane's — so one
    // refresh here serves all of them.
    void sessionsListStore.refresh();
    // `startSession` needs `mounts` populated to pick a primary ICM.
    // `AppFrame` cold-starts it, but only when nothing has loaded it yet;
    // this route refreshes unconditionally because it is one of the two that
    // own the store.
    void mountsStore.refresh();
  });

  // Task 9.4's route scheme: `?icm=<key>` ONLY ever selects the ICM for a
  // brand-new session (`resolveIcmSelection`, shared with Knowledge's
  // identical default), falling back to the first enabled, non-degraded mount
  // in config order when absent. Only ever called from `startSession` — i.e.
  // only when CREATING a session — so it deliberately never looks at
  // `?session=`: a currently open transcript is never reassigned by either
  // query param.
  function primaryMountKey(): string | null {
    const enabledMountKeys = mountsStore.mounts
      .filter((m) => m.enabled && !m.degraded)
      .map((m) => m.mountKey);
    return resolveIcmSelection(page.url.searchParams.get('icm'), enabledMountKeys);
  }

  // Authoritative for the open transcript — driven ENTIRELY by `?session=`;
  // `?icm=` is never consulted here, so it can never reassign which session's
  // channel this page joins.
  const selectedId = $derived(page.url.searchParams.get('session'));

  // `?all=1` opens the primary's sessions navigator (the sidebar's "Show all"
  // row). By default the chat route renders without one, since the main nav's
  // project groups already carry the recent sessions.
  const showAllPane = $derived(chatNavigatorFromUrl(page.url));

  // The primary's chrome state. A side pane's is created by `PaneHost` and
  // toggled from its header; the primary has no header, so its navigator is
  // route state — `?all=1` — exactly as it has always been.
  const primaryChatState = new ChatPaneState();

  $effect(() => {
    primaryChatState.sessionsVisible = showAllPane;
  });

  // True whenever the most recent "start a session" attempt hit
  // `harness_unavailable`, or the user followed the empty state's quiet "Run
  // checks" link — shown in place of whatever the main pane would otherwise
  // render. Reset whenever the selected id changes (a fresh session was
  // created, or a different one was picked).
  let doctorOverride = $state(false);
  let startError = $state<string | null>(null);

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
      void goto(hrefWithPanes(`/chat?session=${data.id}`, page.url));
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

  /**
   * Where the primary goes once its session is archived — from `ChatView`'s
   * own header, or from the navigator's per-row button when the archived row
   * is the open one. Deselects the session but KEEPS the panes: archiving is
   * an in-route move, and whatever is open beside the transcript is
   * unaffected by it.
   */
  function afterArchive(): void {
    void goto(hrefWithPanes(showAllPane ? '/chat?all=1' : '/chat', page.url));
  }

  // --- Panes (`?pane=`) ------------------------------------------------------
  //
  // The URL is the ONE source of truth for what sits beside the transcript, so
  // a composition is linkable, survives reload, and Back closes a pane.
  // `dedupeSurfaces` drops a pane that would duplicate this route's own chat
  // surface, and always allocates — which is what keeps `PaneHost` re-deriving
  // its row layout rather than writing stale sizes back over a dragged ratio.
  //
  // `?session=` names an open transcript; `?icm=` with no session is the
  // NEW-session composer (what `routeFor({kind:'chat-new'})` promotes to, and
  // where Knowledge's "start a session with this entry" navigates). `?from=`
  // carries the origin, serialized exactly as it is inside a pane param —
  // `chatNewParam` composes the two into that one wire form, so the route and
  // a pane can never read an origin differently.
  //
  // The route does NOT inherit the parser's guarantee whole. `parsePaneParam`
  // fails the WHOLE descriptor on an unreadable origin so a detached composer
  // can never look like an attached one; here that null falls through to the
  // empty state below, whose "Start a session" button calls `startSession` —
  // which still reads the same `?icm=` and would create the very session the
  // parser refused. That is tolerable only because the empty state makes no
  // attachment claim: nothing on it says "about this message", so a session
  // started from it is an ordinary blank session and the user is not misled.
  // A composer that rendered normally while attached to nothing would not be.
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    selectedId ? { kind: 'chat', sessionId: selectedId } : parsePaneParam(chatNewParam(page.url))
  );
  const panes = $derived(dedupeSurfaces(primaryDescriptor, parsePanes(page.url.searchParams)));

  // No `openInPrimary`: the primary here is a transcript, so a file opened
  // from a tool chip lands in the Files pane — creating one if there is none.
  // `primary` and `slots` are what let the session header's "Open files" refuse
  // visibly: the first tells `besideRefusal` this route's own surface counts
  // toward `dedupeSurfaces`, the second gives it the window's width.
  const wiring = paneWiring({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor,
    slots: () => paneRoom.slots
  });

  // Reopen whatever was last beside a transcript, but only when the URL names
  // nothing itself — see `pane-memory.svelte.ts` for the three rules.
  watchPaneMemory({
    url: () => page.url,
    panes: () => panes,
    primary: () => primaryDescriptor
  });

  /**
   * The composer this route is showing as its PRIMARY started its session.
   * The pane host answers this by rewriting that pane's descriptor; the
   * primary's descriptor IS the URL, so it navigates — which is what turns
   * `paneIdentity` from `chat-new:…` into `chat:<id>`, mounts a fresh
   * `ChatView`, and lets it fire the prompt it stashed.
   *
   * `?icm=`/`?from=` are deliberately dropped: the composer is spent. It
   * REPLACES rather than pushes, exactly as the pane host does, so Back does
   * not step onto a dead composer whose message has already been sent.
   */
  function startedAsPrimary(id: string): void {
    const target = `/chat?${showAllPane ? 'all=1&' : ''}session=${encodeURIComponent(id)}`;
    void goto(hrefWithPanes(target, page.url), { replaceState: true });
  }

  /**
   * A row in the sessions navigator. `ChatPane` calls `context.openPane` for
   * it — the same call a SIDE pane uses to rewrite its own descriptor — and
   * for the primary "rewrite my own descriptor" means navigating this route
   * (`PaneContext.openPane`'s doc says exactly that).
   *
   * Without it every row of `?all=1` is a dead button: the call is
   * optional-chained, so a missing handler is silent.
   *
   * `?all=1` survives the move, or picking a session from the list would
   * close the list you picked it from; `hrefWithPanes` keeps whatever is open
   * beside the transcript, since switching sessions is an in-route move.
   */
  function openSessionAsPrimary(d: PaneDescriptor): void {
    if (d.kind !== 'chat') return;
    const target = `/chat?${showAllPane ? 'all=1&' : ''}session=${encodeURIComponent(d.sessionId)}`;
    void goto(hrefWithPanes(target, page.url), { keepFocus: true, noScroll: true });
  }

  // Stable identity on purpose: `ChatView` derives from `context.openFile`,
  // and a fresh object every render would churn that for no reason. Both
  // `openBeside` members are the wiring's own — the session header's "Open
  // files" must meet exactly the gate a pane-placed session meets, or the two
  // placements disagree about what the row will accept.
  const primaryContext: PaneContext = {
    placement: 'primary',
    openPane: openSessionAsPrimary,
    openFile: wiring.openFileSurface,
    openBeside: wiring.openBeside,
    besideRefusal: wiring.besideRefusal,
    // The other two thirds of the session header's file-browser TOGGLE.
    besideOpen: wiring.besideOpen,
    closeBeside: wiring.closeBeside,
    sessionCreated: startedAsPrimary,
    onArchived: afterArchive
  };
</script>

<AppFrame>
  {#snippet main()}
    <!-- The doctor override deliberately sits OUTSIDE `PaneHost`: it replaces
         the whole content area (it's the "the assistant isn't wired up"
         screen), so splitting it next to a file would be nonsense. `?pane=`
         survives in the URL, so dismissing the override restores the row. -->
    {#if doctorOverride}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
        <DoctorPanel />
      </div>
    {:else}
      <PaneHost
        {primaryDescriptor}
        {panes}
        paneContext={wiring.paneContext}
        onClose={wiring.closePane}
        onPromote={wiring.promotePane}
      >
        {#snippet primary()}
          <!-- Both chat descriptors reach `ChatView`: a transcript, and the
               new-session composer a `?icm=` with no `?session=` describes.
               A null descriptor is the "no session selected" state. The
               navigator still renders beside it, because "Show all" lands
               here with nothing selected and an empty state with no way to
               pick a session would be a dead end. -->
          <ChatPane
            descriptor={primaryDescriptor?.kind === 'chat' ||
            primaryDescriptor?.kind === 'chat-new'
              ? primaryDescriptor
              : null}
            context={primaryContext}
            state={primaryChatState}
          >
            {#snippet empty()}
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
            {/snippet}
          </ChatPane>
        {/snippet}
      </PaneHost>
    {/if}
  {/snippet}
</AppFrame>
