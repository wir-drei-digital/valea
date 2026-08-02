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
  import { onMount } from 'svelte';
  import Paperclip from '@lucide/svelte/icons/paperclip';
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
  import { checkExistence, deriveFileActivity } from '$lib/components/agent/file-activity';
  import type {
    ChatPaneDescriptor,
    ChatNewPaneDescriptor,
    PaneOrigin
  } from '$lib/panes/pane-route';
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

  /**
   * The file browser beside this session — files-beside-chat, created from the
   * chat side, replacing the popover file tree this header used to carry.
   *
   * The subject is the session's own ICM, so a session whose mount is not
   * known yet (the flat list is still loading, or the row carries no
   * `icmMount`) offers no control rather than one that would open a browser
   * over the wrong workspace. Every other refusal is the host's
   * `besideRefusal`, so this control and the route's agree by construction.
   */
  const canOpenFiles = $derived(openMountKey !== null && context.openBeside !== undefined);
  /**
   * A TOGGLE, not an opener. It used to disable itself while a file browser
   * was open and say "the file browser is already open beside this" — which is
   * the state it spends most of its life in, and pointing at a pane the user
   * can plainly see is not worth a control. Pressing it now closes that pane,
   * and the browser comes back with its tabs when it is pressed again
   * (`pane-memory.ts`).
   */
  const filesOpen = $derived(context.besideOpen?.('files') ?? false);
  /**
   * Every refusal EXCEPT "already open", which is what this button now does
   * rather than what stops it. The rest — the pane cap, a window too narrow —
   * still apply, because they are about the row this pane would join.
   */
  const filesRefusal = $derived(filesOpen ? null : (context.besideRefusal?.('files') ?? null));

  function toggleFilesBeside(): void {
    if (filesOpen) {
      context.closeBeside?.('files');
      return;
    }
    const key = openMountKey;
    if (!key) return;
    context.openBeside?.({ kind: 'files', mountKey: key, paths: [], active: 0, compare: null });
  }

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

  // (The root-load safety net that used to live here went with the header's
  // popover file tree: it existed only to make sure that popover had a mount
  // root to render. The tree is a Files pane now, and `FilesPane` reads the
  // same store through `IcmTree`, whose own self-healing loader fetches any
  // open folder it finds unloaded.)

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

  /**
   * What the attachment chip says — the whole visible evidence that this
   * composer is pointed at a source, now that the entry points no longer send
   * a canned first turn.
   *
   * A `$derived` reading `descriptor`, never a value captured at init:
   * `label` is deliberately excluded from `paneIdentity` (Task 4), so a
   * label-only change RE-RENDERS this pane instead of remounting it, and a
   * snapshot would show the stale label for the rest of the pane's life.
   *
   * `||` and `.trim()` at every step, not `??`: the chain must not be able to
   * produce a BLANK chip. `parseOrigin` only rejects a FALSY label, so a
   * whitespace-only one survives it; and a hand-written trailing-slash path
   * (`mail-message/INBOX%2F`) makes the basename `''`. Neither is nullish, so
   * `??` would hand the chip an empty string and render an icon with nothing
   * beside it. Null when nothing is displayable — then no chip renders at all,
   * which is honest, where a blank one is just broken.
   *
   * SECURITY: `label` is URL-supplied and untrusted. It is display-only —
   * every grant comes from `path` (see `createAndPrompt`) — it is capped at
   * `ORIGIN_LABEL_CAP` by the parser, and it reaches the DOM only through
   * plain interpolation. Never `{@html}`.
   */
  const originLabel = $derived.by(() => {
    const from = descriptor.kind === 'chat-new' ? descriptor.from : null;
    if (!from) return null;
    // Dropping empty segments makes "INBOX/" read as "INBOX" rather than
    // falling through to the full path — a basename is what a human can use.
    const segments = from.path
      .split('/')
      .map((s) => s.trim())
      .filter(Boolean);
    return from.label?.trim() || segments[segments.length - 1] || from.path.trim() || null;
  });

  // The descriptor's origin kind is HYPHENATED (`PaneOrigin['kind']`); the
  // create action's wire spelling is UNDERSCORED and allowlisted server-side
  // to exactly these three values — anything else fails the action closed.
  // This table is the one place the two spellings meet. It is deliberately a
  // TOTAL `Record` over `PaneOrigin['kind']`: a fourth origin kind breaks
  // this file's build instead of silently shipping a value the backend
  // rejects at runtime.
  const WIRE_ORIGIN_KIND: Record<PaneOrigin['kind'], 'mail_message' | 'page' | 'file'> = {
    'mail-message': 'mail_message',
    page: 'page',
    file: 'file'
  };

  /**
   * The unsent text of the new-session composer, held HERE rather than
   * inside `Composer`, because this is the one `onSend` that can be refused:
   * `Composer.submit` empties the box the instant it hands the text over,
   * and every `return false` below happens after that. Without somewhere to
   * hand it back, "The session could not be started. Please try again." /
   * "Close this composer and start again" would land on a user whose
   * paragraph had just been deleted — the one way the composer flow would be
   * worse than the canned prompt it replaced.
   */
  let composerDraft = $state('');

  async function sendFromComposer(text: string): Promise<void> {
    if (!(await createAndPrompt(text))) composerDraft = text;
  }

  /** True only if a session was created; every refusal returns false so the text survives. */
  async function createAndPrompt(text: string): Promise<boolean> {
    if (descriptor.kind !== 'chat-new' || creating) return false;
    creating = true;
    createError = null;

    // PARSED IS NOT RESOLVABLE. The pane codec validates the origin's SHAPE
    // only — a well-formed URL can still name a mount whose manifest has no
    // loadable id (degraded, unmounted since, hand-written link). A `page`/
    // `file` origin needs that id to build its ICM locator, so when it is
    // missing we REFUSE to create and say so. Silently dropping `from` and
    // creating a blank session would produce a session that looks normal
    // while being detached from what it was opened from — the exact bug this
    // feature exists to prevent. A `mail-message` origin needs no ICM id (it
    // carries a workspace-relative locator plus its own mail mount), so it is
    // exempt from both the lookup and the refusal.
    const from = descriptor.from;
    const icmId =
      from && from.kind !== 'mail-message'
        ? mountsStore.mounts.find((m) => m.mountKey === descriptor.mountKey)?.id
        : undefined;

    if (from && from.kind !== 'mail-message' && !icmId) {
      creating = false;
      createError = 'This project has no loadable identity. Run Diagnose from the sidebar.';
      return false;
    }

    // The grant is derived from `from.path` — never from `from.label`, which
    // is untrusted URL text and display-only.
    const opts =
      from === null
        ? undefined
        : from.kind === 'mail-message'
          ? {
              input: { kind: 'workspace' as const, path: from.path },
              includeMounts: from.mount ? [from.mount] : [],
              openedFromKind: WIRE_ORIGIN_KIND[from.kind]
            }
          : {
              contextDoc: { kind: 'icm' as const, icm_id: icmId as string, path: from.path },
              openedFromKind: WIRE_ORIGIN_KIND[from.kind]
            };

    const result = await api.createAgentSession(
      descriptor.mountKey,
      workspaceStore.generation ?? 0,
      opts
    );
    creating = false;
    if (!result.ok) {
      createError =
        result.error === 'harness_unavailable'
          ? "The assistant isn't ready — open Agent settings (the gear in the sidebar) and run the checks."
          : result.error === 'input_unavailable' || result.error === 'context_doc_unavailable'
            ? 'That file is no longer there. Close this composer and start again from the message or page.'
            : 'The session could not be started. Please try again.';
      return false;
    }
    const data = result.data as { id: string };
    setInitialPrompt(data.id, text);
    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    context.sessionCreated?.(data.id);
    return true;
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

  // --- File activity (spec: 2026-07-30-session-file-activity-design) --------
  //
  // Aggregation is a plain derived over the same items the transcript reads.
  //
  // IT IS A POPOVER, ALWAYS. It used to be an inline right-hand rail that
  // OPENED ITSELF the first time a session touched a file, falling back to a
  // popover only where the rail could not fit — which meant the same session
  // laid itself out two different ways depending on the window, and the layout
  // moved under the reader mid-turn, while a pane they had opened on purpose
  // competed for the same edge. The list is a record you consult, not a
  // surface you work in, so it now waits behind the header's "Context · N"
  // pill and nothing but a click opens it.
  //
  // Retired with the rail: `shouldAutoOpen` and `ClosedRailMemory`
  // (`file-activity.ts`), whose whole purpose was remembering that you had
  // closed something that no longer opens by itself.
  const fileActivities = $derived.by(() => (store ? deriveFileActivity(store.items) : []));

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
    // No `hasOpenPane` gate any more. "Never evict a file the user placed" is
    // still the floor, but it lives where the file actually lands — the Files
    // surface's own auto-open rule (`auto-open.ts`, rule 3) — rather than
    // here, where "a pane is open" had stopped meaning "there is nowhere to
    // put this" the moment a row could hold two panes and a Files pane two
    // splits. This view just offers the file and lets the receiver decide.
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
      // Re-checked after the await, because the transcript may have moved on
      // while `icm_paths_exist` was out — but NOT re-checked against pane
      // state, which is no longer this view's business (see the effect above).
      if (store !== captured || turnCount(captured.items) !== capturedTurnCount) return;
      open(relPath);
    } finally {
      autoOpenInFlight = false;
    }
  }

  // Existence notes: reality-check changed rows against the mount tree via
  // `ensurePathLoaded` — ONLY its definitive 'missing' marks a row (store
  // issue-#2 contract). Re-runs are scoped to: changed-row-SET changes (the
  // `changedRelPaths` key — the `fileActivities` read below happens AFTER an
  // `await`, which Svelte does not track, so a mere diff/index mutation on an
  // already-listed row doesn't re-trigger), a `groups` REASSIGNMENT (which is
  // how every `icm_changed` refetch lands), the open mount, and the effect's
  // own first run on mount. Deliberately NOT the
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
    // Applicable whenever there is a list to reach: the pill is the one
    // affordance now, and the popover must not silently omit the "no longer
    // exists" notes.
    if (fileActivities.length === 0 || !key) {
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
  <!-- The header pill's popover content, and the only place this list renders
       now: no panel chrome and no ✕, because the popover card provides the
       first and its own dismissal the second. -->
  <FileActivityRail activities={fileActivities} {missingKeys} onOpenFile={openToolFile} />
{/snippet}

{#if descriptor.kind === 'chat-new'}
  <!-- Same geometry as a live session — full-width header band, centered
       660px body/composer — so promoting the created session in place
       doesn't shift the composer. -->
  <div class="flex min-h-0 w-full flex-1 flex-col pt-3">
    <SessionHeader
      icmName={openIcmName}
      ended={false}
      archiving={false}
      onToggleFiles={canOpenFiles ? toggleFilesBeside : undefined}
      {filesOpen}
      {filesRefusal}
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
      {#if originLabel}
        <!-- Without this the change trades a canned turn the user did not want
             for an empty box with no visible evidence the source is in play.
             See `originLabel` for the untrusted-label and blank-chip notes.
             `text-ink-subtitle`, not `text-ink-meta`: meta ink on this tint is
             2.79:1, and this chip is the session's ONLY attachment signal, not
             a count sitting beside legible text. The paperclip is decorative,
             so the relation it draws has to exist in text for a screen reader
             — hence the visually-hidden prefix. -->
        <div class="px-4 pb-2">
          <span
            class="bg-paper-track text-ink-subtitle inline-flex max-w-full items-center gap-1.5 truncate rounded-md px-2 py-1 text-[12px]"
          >
            <Paperclip class="size-3.5 shrink-0" aria-hidden="true" />
            <span class="sr-only">Attached: </span>
            <span class="truncate">{originLabel}</span>
          </span>
        </div>
      {/if}
      <Composer
        bind:draft={composerDraft}
        busy={creating}
        configItems={[]}
        onSend={(text) => void sendFromComposer(text)}
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
  <div class="flex min-h-0 w-full flex-1">
    <!-- Full-width column: the header band and its border span the whole
         chat area, and the transcript's scrollbar sits at the pane's right
         edge — while the message stream and composer stay centered at 660px
         inside their own wrappers. -->
    <div class="flex min-h-0 min-w-0 flex-1 flex-col pt-3">
      <!-- The "Context · N" pill is a POPOVER wherever it renders. It used to
           be a popover only where the inline rail could not fit and a rail
           opener everywhere else, which made the same pill do two different
           things depending on how wide the window was. -->
      <SessionHeader
        icmName={openIcmName}
        {ended}
        {archiving}
        {deleting}
        onArchive={() => void archiveOpenSession()}
        onDelete={() => void deleteOpenSession()}
        filesCount={fileActivities.length}
        filesPanel={filesPopover}
        onToggleFiles={canOpenFiles ? toggleFilesBeside : undefined}
        {filesOpen}
        {filesRefusal}
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
  </div>
{:else}
  <p class="text-ink-meta px-8 py-8 text-[13px]">Loading…</p>
{/if}
