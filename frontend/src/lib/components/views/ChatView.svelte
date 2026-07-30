<script lang="ts">
  // One agent session, as a mountable VIEW (side-panes pass): everything the
  // chat route's main pane used to do inline — join the session's channel,
  // stream its transcript, keep the sidebar's session rows honest, resume an
  // ended session in place, archive it — driven by a `PaneDescriptor` prop
  // rather than by the URL. That is the whole point of the extraction: the
  // same component renders as `/chat`'s primary view AND inside a side pane
  // next to a file (Task 8), so it must never read `page.url` itself, and
  // must never `goto` — hosts decide what a navigation means (see
  // `PaneContext`).
  //
  // LIFECYCLE: this component joins EXACTLY ONE channel — the per-session
  // `agent_session:<id>` topic, via `AgentSessionStore`. It must never join
  // `workspace:events`: there is one join for that topic in the whole app
  // (the root layout's `wireIcmEvents`), and a second one races it (Phoenix
  // delivers a push only to the channel object whose `join_ref` matches).
  // The store effect below is keyed on the SESSION ID alone for the same
  // family of reasons — an unrelated URL change (e.g. opening a side pane,
  // `?pane=`) must not tear down and rejoin a live session's channel.
  import { onMount, tick } from 'svelte';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { mountsStore } from '$lib/stores/mounts.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { sessionsListStore } from '$lib/stores/sessions-list.svelte';
  import { AgentSessionStore } from '$lib/stores/agent-session.svelte';
  import { takeInitialPrompt, setInitialPrompt } from '$lib/stores/initial-prompt';
  import {
    Transcript,
    PlanBar,
    Composer,
    DoctorPanel,
    SessionHeader,
    FileActivityRail
  } from '$lib/components/agent';
  import { sessionInfoTitle } from '$lib/components/agent/item-shapes';
  import { turnCount, latestTurnAutoOpenPath } from '$lib/components/agent/auto-open';
  import {
    checkExistence,
    closedRailMemory,
    deriveFileActivity,
    shouldAutoOpen
  } from '$lib/components/agent/file-activity';
  import type { ChatPaneDescriptor, ChatNewPaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';

  let {
    descriptor,
    context
  }: {
    descriptor: ChatPaneDescriptor | ChatNewPaneDescriptor;
    context: PaneContext;
  } = $props();

  // The ONE key the store lifecycle is allowed to depend on. Deliberately a
  // primitive: `descriptor` is an object literal at most call sites (a fresh
  // identity on every host re-render), while this derived only propagates
  // when the id actually changes.
  const sessionId = $derived(descriptor.kind === 'chat' ? descriptor.sessionId : null);

  // The host may have nowhere to put a file — in that case the header keeps
  // its plain, static folder line (no popover), and the tree never loads.
  const openFile = $derived(context.openFile);

  let store: AgentSessionStore | null = $state(null);

  $effect(() => {
    const id = sessionId;
    if (!id) {
      store = null;
      return;
    }
    // `takeInitialPrompt` consumes the one-shot handoff (`initial-prompt.ts`)
    // stashed by a session entry point (e.g. Knowledge's "Start a session
    // with this page", or this view's own new-session mode below) right
    // before the descriptor became `chat:<id>` — the store fires it as the
    // first user turn once its channel join succeeds. A plain sessions-list
    // click or a reload finds nothing pending, which is safe.
    const session = new AgentSessionStore(id, { initialPrompt: takeInitialPrompt(id) });
    store = session;
    return () => {
      session.dispose();
    };
  });

  onMount(() => {
    // The flat list backs `summary` below (which ICM this session runs in).
    // Only fetched when nothing has loaded it yet — the chat route's list
    // pane, the sidebar, or another mounted ChatView may already have.
    if (!sessionsListStore.loaded) void sessionsListStore.refresh();
  });

  // Task 9.3's KNOWN GAP, closed here (frontend-only, sanctioned — see the
  // brief): there is no workspace-level "a session's status changed"
  // broadcast (`recent-sessions.svelte.ts`'s `wireRecentSessionsEvents` doc
  // comment explains why — `SessionServer`'s status push only rides the
  // per-session `agent_session:<id>` topic this view joins, never the
  // shared `workspace:events` join `recentSessionsStore` listens on).
  // So: observe the OPEN session's own `status` here (the one place with a
  // live per-session subscription) and refresh the sidebar's project groups
  // whenever it actually TRANSITIONS — an ended/failed/exited session
  // elsewhere would otherwise show as live in the sidebar until some
  // unrelated `mounts_changed` push happened to refresh it. Deliberately
  // only-on-transition, not on every render: switching `store` to a
  // DIFFERENT (or no) session resets tracking without firing — that
  // session's own creation/selection already triggered whatever refresh it
  // needed (`IcmProjects.svelte`'s `startSession` refreshes right after
  // `createAgentSession` succeeds), so re-observing its starting status here
  // would be a redundant, not a missing, refresh.
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
  // session's live title is the one signal this view can observe, so it
  // re-fetches both the flat session list and the sidebar's project groups.
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
        void sessionsListStore.refresh();
        void recentSessionsStore.refresh();
      }
    }
  });

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

  // --- Which ICM this session runs in ---
  //
  // ("in the chat session, it is not clear for which ICM the current session
  // is active".) The summary's own `icmName`/`icmMount` (session/v1
  // metadata, threaded through `trim_summary/1`) is authoritative; the
  // recent-sessions groups are both a fallback while the flat list is still
  // loading (a freshly created session reaches this view right after
  // `sessionsListStore.refresh()`, so the gap is brief) and the second
  // source of the same rows.
  const summary = $derived.by(() => {
    if (!sessionId) return undefined;
    return (
      sessionsListStore.sessions.find((s) => s.id === sessionId) ??
      recentSessionsStore.groups.flatMap((g) => g.sessions).find((s) => s.id === sessionId)
    );
  });

  const openMountKey = $derived.by(() => {
    if (descriptor.kind === 'chat-new') return descriptor.mountKey;
    if (summary?.icmMount) return summary.icmMount;
    return (
      recentSessionsStore.groups.find((g) => g.sessions.some((s) => s.id === sessionId))?.mountKey ?? null
    );
  });

  const openIcmName = $derived.by(() => {
    // New-session mode has no session row to read a name off yet — the mount
    // catalog is the only source (`MountSummary.name` is the ICM's display
    // name; `mountKey` is the stable config key).
    if (descriptor.kind === 'chat-new') {
      const key = descriptor.mountKey;
      return mountsStore.mounts.find((m) => m.mountKey === key)?.name ?? null;
    }
    if (summary?.icmName) return summary.icmName;
    return (
      recentSessionsStore.groups.find((g) => g.sessions.some((s) => s.id === sessionId))?.icmName ?? null
    );
  });

  // Safety net for the header's popover file tree, which reads
  // `icmStore.groups`: every shell already refetches that store on mount
  // (`AppFrame`, Today's inline shell), so this normally never fires. Three
  // guards, each load-bearing:
  //  - no `openFile` → no popover renders → nothing to load;
  //  - `!icmStore.loaded` → the shell's own cold-load refetch is still in
  //    flight, and firing a second full refetch alongside it would double
  //    every `list_icms`/`icm_list_dir` call on every cold load;
  //  - once per mount key → `refetch()` REASSIGNS `groups`, this effect's own
  //    dependency, so a mount that never appears in it (disabled, degraded —
  //    `refetch` filters those out) would otherwise refetch in a tight loop.
  // Deeper folders lazy-load on expand through `IcmTree`'s own `loadDir`.
  let treeRequestedFor: string | null = null;

  $effect(() => {
    if (!openFile) return;
    if (!icmStore.loaded) return;
    const key = openMountKey;
    if (!key || treeRequestedFor === key) return;
    if (icmStore.groups.some((g) => g.mount === key)) return;
    treeRequestedFor = key;
    void icmStore.refetch();
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
  // creation (see the route's `startSession` and `createAndPrompt` below), so
  // a joined session cannot currently reach this state — kept as a guard in
  // case that resolution ever moves post-join.
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
    const id = sessionId;
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
    void sessionsListStore.refresh();
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

  // --- Archive the OPEN session. Live sessions archive too — the backend
  // stops a running session first, then archives
  // (`Valea.Agents.archive_session/1`), so the header offers this whatever
  // the status is. Where to go afterwards is the HOST's call (`onArchived`):
  // the chat route navigates back to its empty state, a side pane closes
  // itself.

  let archiving = $state(false);
  let archiveError = $state<string | null>(null);

  async function archiveOpenSession(): Promise<void> {
    const id = sessionId;
    if (!id || archiving) return;
    archiveError = null;
    archiving = true;
    const result = await api.archiveAgentSession(id, workspaceStore.generation ?? 0);
    archiving = false;

    if (!result.ok) {
      archiveError = 'Could not archive the session. Please try again.';
      return;
    }

    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    context.onArchived?.();
  }

  // --- Delete the OPEN session — permanent (no archived copy), so the
  // header collects an explicit confirmation before calling this. Live
  // sessions are stopped first backend-side, same as archive. Afterwards
  // the session is gone exactly like an archived one from the host's
  // perspective, so the same `onArchived` navigation applies.

  let deleting = $state(false);

  async function deleteOpenSession(): Promise<void> {
    const id = sessionId;
    if (!id || deleting) return;
    archiveError = null;
    deleting = true;
    const result = await api.deleteAgentSession(id, workspaceStore.generation ?? 0);
    deleting = false;

    if (!result.ok) {
      archiveError = 'Could not delete the session. Please try again.';
      return;
    }

    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    context.onArchived?.();
  }

  // --- New-session mode (`chat-new`): no store, no channel — the session
  // doesn't exist until the first message is sent. Creating it stashes that
  // message as the session's initial prompt and hands the id back to the
  // host, which re-points this view at `chat:<id>`; the store effect above
  // then joins and fires the prompt on join, exactly like every other entry
  // point ("Start a session with this page").

  let creating = $state(false);
  let createError = $state<string | null>(null);

  async function createAndPrompt(text: string): Promise<void> {
    if (descriptor.kind !== 'chat-new' || creating) return;
    creating = true;
    createError = null;
    const result = await api.createAgentSession(descriptor.mountKey, workspaceStore.generation ?? 0);
    creating = false;
    if (!result.ok) {
      createError =
        result.error === 'harness_unavailable'
          ? "The assistant isn't ready — open Agent settings (the gear in the sidebar) and run the checks."
          : 'The session could not be started. Please try again.';
      return;
    }
    const data = result.data as { id: string };
    setInitialPrompt(data.id, text);
    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    context.sessionCreated?.(data.id);
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
    void sessionId;
    pinned = true;
  });

  // Tool-call file chips. A location's `relPath` is relative to the ICM this
  // session runs in, so both halves must be present: a host that can open
  // files AND a known mount. Otherwise the chips render as plain text (see
  // `ToolCallCard`) — same rule the header's popover tree follows.
  const openToolFile = $derived.by(() => {
    const key = openMountKey;
    const open = openFile;
    if (!key || !open) return undefined;
    return (relPath: string) => open({ mountKey: key, path: relPath });
  });

  // --- File-activity rail (spec: 2026-07-30-session-file-activity-design) ---
  //
  // Aggregation is a plain derived over the same items the transcript reads.
  // Auto-open fires only on the derived count's 0 -> >0 transition (attach
  // included), and never for a session the user closed the rail on
  // (`closedRailMemory`, this app run only). Rendering is additionally gated
  // on primary placement and container width >= 860px — the rail yields to a
  // squeezed layout (e.g. an open side pane at PaneHost's 30% minimums).
  const fileActivities = $derived.by(() => (store ? deriveFileActivity(store.items) : []));

  let railOpen = $state(false);
  let railCountStore: AgentSessionStore | null = null;
  let previousFileCount = 0;

  $effect(() => {
    const current = store;
    const count = fileActivities.length;
    if (current !== railCountStore) {
      // New (or no) session: reset tracking, then let the 0 -> count check
      // below run against THIS session's own baseline.
      railCountStore = current;
      previousFileCount = 0;
      railOpen = false;
    }
    const id = sessionId;
    if (
      id !== null &&
      !railOpen &&
      shouldAutoOpen(previousFileCount, count, closedRailMemory.isClosed(id))
    ) {
      railOpen = true;
    }
    previousFileCount = count;
  });

  // Close/reopen each unmount the control that had focus (the rail's ✕, the
  // header pill) — without a hand-off, keyboard focus falls to <body> and the
  // user re-tabs from the top. So each side passes focus to its counterpart
  // after the DOM settles. The ids are unique per page: rail and pill only
  // render in the one primary-placement ChatView.
  function closeRail(): void {
    railOpen = false;
    if (sessionId !== null) closedRailMemory.close(sessionId);
    void tick().then(() => document.getElementById('session-files-pill')?.focus());
  }

  function reopenRail(): void {
    railOpen = true;
    if (sessionId !== null) closedRailMemory.reopen(sessionId);
    void tick().then(() => document.getElementById('file-activity-rail')?.focus());
  }

  // --- Auto-open a reply's single named file (message-file-links spec §3) ---
  //
  // Baseline is the turn count seen when THIS store attached — the OPPOSITE
  // of the rail's fire-on-attach baseline: history must never open a pane.
  // Each live increment is consumed exactly once (baseline advances even
  // when a guard fails). The RPC verification captures store + turn count
  // before the await and re-checks after (MarkdownPageView.refreshDangling's
  // staleness shape) so a queued prompt starting the next turn mid-flight
  // drops the result.
  //
  // The existence check needs the mount's ABSOLUTE root, not its key:
  // `Valea.Api.ICM`'s `find_mount/2` prefix-matches the path string AS GIVEN
  // against the mount roots (backend/lib/valea/api/icm.ex:458-479) — that
  // match runs BEFORE `target_abs/2` (icm.ex:492-496) anchors a relative path
  // to the workspace. So a `<mountKey>/<relPath>` join attributes to no mount
  // at all — regardless of where the roots live — and reports `exists: false`
  // for even a real file (verified against the RPC). `MountSummary.root` is
  // that resolved path; the catalog not being loaded yet simply means no
  // auto-open for that turn.
  const openMountRoot = $derived.by(() => {
    const key = openMountKey;
    if (!key) return null;
    return mountsStore.mounts.find((m) => m.mountKey === key)?.root ?? null;
  });

  let autoOpenStore: AgentSessionStore | null = null;
  let autoOpenBaseline = 0;
  let autoOpenInFlight = false;

  $effect(() => {
    const current = store;
    const count = current ? turnCount(current.items) : 0;
    if (current !== autoOpenStore) {
      autoOpenStore = current;
      autoOpenBaseline = count;
      return;
    }
    if (!current || count <= autoOpenBaseline) return;
    autoOpenBaseline = count;
    const open = openToolFile;
    if (!open || context.placement !== 'primary') return;
    if (context.hasOpenPane === undefined || context.hasOpenPane()) return;
    if (autoOpenInFlight) return;
    const relPath = latestTurnAutoOpenPath(current.items);
    const mountRoot = openMountRoot;
    if (!relPath || !mountRoot) return;
    autoOpenInFlight = true;
    void verifyAndAutoOpen(current, count, mountRoot, relPath, open);
  });

  async function verifyAndAutoOpen(
    captured: AgentSessionStore,
    capturedTurnCount: number,
    mountRoot: string,
    relPath: string,
    open: (relPath: string) => void
  ): Promise<void> {
    try {
      const result = await api.icmPathsExist([`${mountRoot}/${relPath}`]);
      if (!result.ok) return;
      const data = result.data as { results: { path: string; exists: boolean }[] };
      if (!data.results[0]?.exists) return;
      if (store !== captured || turnCount(captured.items) !== capturedTurnCount) return;
      if (context.hasOpenPane?.() !== false) return;
      open(relPath);
    } finally {
      autoOpenInFlight = false;
    }
  }

  let viewWidth = $state(0);
  // Where the INLINE rail can exist at all; when false, the header pill
  // switches to popover mode (`filesPanel` below) instead of vanishing —
  // the file-activity affordance defers with the layout, never deletes.
  const railCanShow = $derived(context.placement === 'primary' && viewWidth >= 860);
  const showRail = $derived(railOpen && railCanShow && fileActivities.length > 0);

  // Existence notes: reality-check changed rows against the mount tree via
  // `ensurePathLoaded` — ONLY its definitive 'missing' marks a row (store
  // issue-#2 contract). Re-runs are scoped to: changed-row-SET changes (the
  // `changedRelPaths` key — the `fileActivities` read below happens AFTER an
  // `await`, which Svelte does not track, so a mere diff/index mutation on an
  // already-listed row doesn't re-trigger), a `groups` REASSIGNMENT (which is
  // how every `icm_changed` refetch lands), the open mount, rail visibility,
  // and the effect's own first run on mount. Deliberately NOT the
  // `onIcmChanged` listener: that fires BEFORE the refetch settles, so a
  // tick-based recheck would walk the stale tree through `loadDir`'s
  // loaded-dir cache and miss a deletion permanently (Codex review finding).
  // Reading `groups` cannot loop this effect: `ensurePathLoaded`'s own lazy
  // loads GRAFT into existing nodes without reassigning the array, and the
  // effect reads nothing deeper than the array reference.
  // The run token invalidates pending resolutions on EVERY re-run —
  // including the not-applicable branch, so a stale async result can never
  // land after the rail closed or the mount changed.
  let missingKeys = $state<ReadonlySet<string>>(new Set());
  let existenceRun = 0;

  const changedRelPaths = $derived(
    fileActivities
      .filter((r) => r.kindBadge !== 'read' && r.relPath !== undefined)
      .map((r) => r.key)
      .join('\n')
  );

  $effect(() => {
    void changedRelPaths;
    void icmStore.groups;
    const key = openMountKey;
    const token = ++existenceRun;
    // Applicable when the file list is REACHABLE: the inline rail is shown,
    // or the popover pill is the affordance (`!railCanShow`) — the popover
    // must not silently omit "no longer exists" notes the rail would show.
    const applicable = showRail || (!railCanShow && fileActivities.length > 0);
    if (!applicable || !key) {
      missingKeys = new Set();
      return;
    }
    void (async () => {
      // Settle: a just-created file is invisible to the CACHED tree until the
      // debounced icm_changed refetch (~200ms) reassigns `groups` and re-runs
      // this effect. Checking immediately would flash a false "no longer
      // exists" on every file the session creates. The run token discards
      // this pass if anything re-triggered meanwhile.
      await new Promise((resolve) => setTimeout(resolve, 750));
      if (token !== existenceRun) return;
      // Read AFTER the await (untracked, so it isn't an effect dependency) —
      // still the CURRENT activities, since a `$derived` recomputes on read.
      const rows = fileActivities;
      const missing = await checkExistence(rows, async (relPath) => {
        const result = await icmStore.ensurePathLoaded(key, relPath);
        return result.status;
      });
      if (token === existenceRun) missingKeys = missing;
    })();
  });
</script>

{#snippet filesPopover()}
  <!-- The header pill's popover content where the inline rail can't fit —
       same component, popover variant (no panel chrome, no ✕, popover
       dismissal). -->
  <FileActivityRail
    variant="popover"
    activities={fileActivities}
    {missingKeys}
    onOpenFile={openToolFile}
  />
{/snippet}

{#if descriptor.kind === 'chat-new'}
  <!-- Same geometry as a live session — full-width header band, centered
       660px body/composer — so promoting the created session in place
       doesn't shift the composer. -->
  <div class="flex min-h-0 w-full flex-1 flex-col pt-3">
    <SessionHeader
      icmName={openIcmName}
      mountKey={openMountKey}
      ended={false}
      archiving={false}
      onOpenFile={openFile ? (sel) => openFile(sel) : undefined}
    />
    <div class="min-h-0 flex-1 overflow-y-auto">
      <p class="text-ink-meta mx-auto w-full max-w-[660px] px-8 py-5 text-[13px]">
        {openIcmName ? `New session in ${openIcmName}.` : 'New session.'} Send a message to start it.
      </p>
    </div>
    <div class="mx-auto w-full max-w-[660px] px-4">
      {#if createError}
        <p class="text-warn-ink px-4 pt-2 text-[12px]" role="alert">{createError}</p>
      {/if}
      <Composer
        busy={creating}
        configItems={[]}
        onSend={(text) => void createAndPrompt(text)}
        onStop={() => {}}
        onSetConfig={() => {}}
      />
    </div>
  </div>
{:else if sessionDoctor}
  <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8">
    <DoctorPanel />
  </div>
{:else if store}
  <!-- Transcript scrolls; the composer (or the ended/starting row) stays
       docked at the pane's bottom edge, per the cockpit chat screen. -->
  <div bind:clientWidth={viewWidth} class="flex min-h-0 w-full flex-1">
    <!-- Full-width column: the header band and its border span the whole
         chat area, and the transcript's scrollbar sits at the pane's right
         edge — while the message stream and composer stay centered at 660px
         inside their own wrappers. -->
    <div class="flex min-h-0 min-w-0 flex-1 flex-col pt-3">
      <!-- The "Context · N" pill renders only where the rail could actually
           show (primary placement, >= 860px): elsewhere clicking it would set
           railOpen, hide the pill, and surface no rail — an inert affordance
           that deletes itself. -->
      <SessionHeader
        icmName={openIcmName}
        mountKey={openMountKey}
        {ended}
        {archiving}
        {deleting}
        onArchive={() => void archiveOpenSession()}
        onDelete={() => void deleteOpenSession()}
        onOpenFile={openFile ? (sel) => openFile(sel) : undefined}
        filesCount={fileActivities.length}
        onShowFiles={railCanShow && !railOpen ? reopenRail : undefined}
        filesPanel={!railCanShow ? filesPopover : undefined}
      />
      {#if archiveError}
        <p class="text-warn-ink mx-auto w-full max-w-[660px] px-8 pt-1 text-[11.5px]" role="alert">
          {archiveError}
        </p>
      {/if}
      <div class="mx-auto w-full max-w-[660px] px-4">
        <PlanBar item={planItem} />
      </div>

      <div bind:this={scroller} onscroll={onTranscriptScroll} class="min-h-0 flex-1 overflow-y-auto">
        <div class="mx-auto w-full max-w-[660px] px-4">
          <Transcript {store} onOpenFile={openToolFile} />
        </div>
      </div>

      <div class="mx-auto w-full max-w-[660px] px-4">
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
    </div>
    {#if showRail}
      <!-- The rail appears and disappears instantly: it is opened and closed
           by direct user action, where an animated width reads as lag on a
           surface you are already looking at. -->
      <div class="flex min-h-0 shrink-0">
        <FileActivityRail
          activities={fileActivities}
          {missingKeys}
          onOpenFile={openToolFile}
          onClose={closeRail}
        />
      </div>
    {/if}
  </div>
{:else}
  <p class="text-ink-meta px-8 py-8 text-[13px]">Loading…</p>
{/if}
