<script lang="ts">
  // Read pane for a selected message, per the cockpit mail screen: subject
  // as the Newsreader page headline beside a compact icon toolbar (reply
  // actions | mailbox ops | ⋯ overflow), one meta row under it (sender-name
  // pill · address · date · recipient, with the technical placement — the
  // workspace file path in mono (§1 ownership signature), folders, flags —
  // one "Details" toggle away), hairline, then the body: the sanitized HTML
  // rendering in its sandboxed iframe, or plain preformatted TEXT on a white
  // reading card (`white-space: pre-wrap`, NOT markdown-rendered, NEVER
  // `{@html}` — untrusted mail content, same inert-interpolation posture
  // elsewhere in this app), attachment chips, then a closing hairline with
  // the reply-only action bar underneath.
  //
  // Spec D deletion wave: the "Run triage" workflow action that used to
  // live in the actions strip below the hairline is gone along with the
  // whole queue/workflow subsystem. Task 11 replaces it with "Start a
  // session about this message" — same exact-read-grant + one-shot opening
  // prompt pattern as Knowledge's "Start a session with this page"
  // (`EntryMenu.svelte`'s `startSessionWithEntry`), just keyed off
  // `message.path` and `contextDoc` swapped for `input` (a workspace
  // locator, not an ICM one — mail messages live outside any ICM's tree).
  import Archive from '@lucide/svelte/icons/archive';
  import Check from '@lucide/svelte/icons/check';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Copy from '@lucide/svelte/icons/copy';
  import Download from '@lucide/svelte/icons/download';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import Flag from '@lucide/svelte/icons/flag';
  import FolderInput from '@lucide/svelte/icons/folder-input';
  import ForwardIcon from '@lucide/svelte/icons/forward';
  import MailIcon from '@lucide/svelte/icons/mail';
  import MailOpen from '@lucide/svelte/icons/mail-open';
  import MessageSquarePlus from '@lucide/svelte/icons/message-square-plus';
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import ReplyIcon from '@lucide/svelte/icons/reply';
  import ReplyAll from '@lucide/svelte/icons/reply-all';
  import Trash2 from '@lucide/svelte/icons/trash-2';
  import { untrack } from 'svelte';
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import HtmlMailView from './HtmlMailView.svelte';
  import { api } from '$lib/api/client';
  import { rawFileOpenUrl } from '$lib/components/files/raw-url';
  import { inDesktop } from '$lib/keychain';
  import { openExternal, prepareExternalOpen } from '$lib/shell/external-link';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import {
    addressEmail,
    addressListLabel,
    addressName,
    attachmentsFromFrontmatter,
    formatBytes,
    formatDateTime,
    fromLabel,
    linkifyText,
    mailAttachmentTarget,
    markReadOp,
    markUnreadOp,
    messageHref,
    messageSeen,
    messageSessionPrompt,
    moveTargets,
    opResultMessage,
    relativeTime,
    subjectLabel,
    trashTarget,
    type RawAddress
  } from './mail-shapes';
  import { composeHref, replyPrefill, setComposePrefill, type ComposeMode } from './compose';
  import type { MailMessageDetail } from '$lib/stores/mail.svelte';

  let {
    message,
    onSessionBeside,
    sessionBesideRefusal = null
  }: {
    message: MailMessageDetail;
    /**
     * Where the session this message starts goes: BESIDE the message, as a
     * chat pane, rather than a navigation to `/chat` that takes the message
     * off screen. The host owns the placement (a route appends to `?pane=`, a
     * pane asks its own host to), which is why this is a callback.
     */
    onSessionBeside: (sessionId: string) => void;
    /**
     * Why no session can open beside this message right now — the row is full,
     * the window is too narrow, or one is already open. Rendered on the button
     * rather than discovered by clicking it; `pane-offer.ts` writes the words.
     */
    sessionBesideRefusal?: string | null;
  } = $props();

  const frontmatter = $derived((message.frontmatter ?? {}) as Record<string, unknown>);
  const subject = $derived(subjectLabel(typeof frontmatter.subject === 'string' ? frontmatter.subject : null));
  const fromName = $derived(addressName(frontmatter.from as RawAddress));
  const fromEmail = $derived(addressEmail(frontmatter.from as RawAddress));
  const to = $derived(addressListLabel(frontmatter.to));
  const date = $derived(typeof frontmatter.date === 'string' ? frontmatter.date : null);
  // "email · date" next to the sender-name pill; falls back to
  // "(unknown sender)" only when the address carried neither part.
  const metaLine = $derived(
    [fromName ? fromEmail : fromEmail || '(unknown sender)', formatDateTime(date)]
      .filter(Boolean)
      .join(' · ')
  );
  // Where this message lives + its IMAP flags — the maildir replacement for
  // the deleted review/processed status marker (spec E: occurrences carry
  // `folders`/`flags` frontmatter; Valea adds no workflow state of its own).
  // Collapsed behind the meta row's "Details" toggle together with the
  // workspace file path (§1's ownership signature — one toggle away, per
  // "plain language first; technical detail one toggle away").
  const detailFolders = $derived(
    Array.isArray(frontmatter.folders)
      ? frontmatter.folders.filter((f): f is string => typeof f === 'string' && f.length > 0).join(', ')
      : ''
  );
  const detailFlags = $derived(typeof frontmatter.flags === 'string' ? frontmatter.flags.trim() : '');
  let showDetails = $state(false);
  const attachments = $derived(attachmentsFromFrontmatter(message.frontmatter));

  /** Shared chrome for the header toolbar's 32×32 icon buttons. */
  const toolbarBtn =
    'text-ink-secondary hover:bg-paper-pill hover:text-ink-heading flex size-8 shrink-0 items-center justify-center rounded-md transition-colors disabled:pointer-events-none disabled:opacity-50';

  let copiedPath: string | null = $state(null);
  /** The attachment whose open is mid-flight — one at a time, and the chip says so. */
  let openingPath: string | null = $state(null);
  let attachmentError = $state<string | null>(null);
  let starting = $state(false);
  let sessionError = $state<string | null>(null);
  /** Which of Reply/Reply-all/Forward is resolving the account's own address, if any. */
  let composing = $state<ComposeMode | null>(null);
  let opBusy = $state(false);
  let opError = $state<string | null>(null);
  /**
   * In-place override of the fetched `S` (Seen) flag after a mark op —
   * `null` = follow the frontmatter. `applyOps` refetches the folder and
   * message LISTS but not the open message's detail, so without this the
   * read action would keep naming the state from before the click.
   */
  let seenOverride = $state<boolean | null>(null);

  // -- HTML rendering + the remote-content trust gate ------------------------
  //
  // `message.html` is the backend-sanitized rendering; it shows inside
  // `HtmlMailView`'s sandboxed iframe. Remote content (images, tracking
  // pixels) loads only for a trusted sender (`message.senderTrusted`,
  // overridable in place by the banner's trust/untrust actions) or after a
  // one-time "Load once" — everything else is CSP-blocked in the iframe.
  let viewMode = $state<'html' | 'text'>('html');
  let allowOnce = $state(false);
  /** In-place override after a trust/untrust RPC — `null` = follow the fetched flag. */
  let trustOverride = $state<boolean | null>(null);
  let trustBusy = $state(false);
  let trustError = $state<string | null>(null);

  const trusted = $derived(trustOverride ?? message.senderTrusted);
  const allowRemote = $derived(trusted || allowOnce);
  const showHtml = $derived(message.html !== null && viewMode === 'html');

  // A text/plain body carries URLs as bare text, so they were dead on screen
  // while the HTML rendering's anchors worked — same message, two answers.
  // `linkifyText` finds them; each run below still reaches the DOM through
  // plain interpolation, so the body stays inert content, not markup.
  const bodySegments = $derived(linkifyText(message.body));

  // Desktop: the Tauri webview has no window factory, so `target="_blank"`
  // silently does nothing — route the click through the desktop-aware
  // opener (external-link.ts). Browser: default anchor behavior.
  // Same handler shape as the agent transcript's markdown links.
  function onLinkClick(event: MouseEvent, href: string): void {
    if (!inDesktop()) return;
    event.preventDefault();
    openExternal(href);
  }

  async function setTrust(trust: boolean): Promise<void> {
    if (!fromEmail || trustBusy) return;
    trustBusy = true;
    trustError = null;
    const result = await api.setMailSenderTrust(fromEmail, trust, workspaceStore.generation ?? 0);
    trustBusy = false;
    if (!result.ok) {
      trustError = 'Could not update the trusted senders list.';
      return;
    }
    trustOverride = trust;
    if (!trust) allowOnce = false;
  }

  // A different message was opened — drop this session's local "just
  // copied a path" affordance, any stale session-start/op error, and the
  // per-message trust/view state so none bleeds into the newly-selected
  // message's view.
  $effect(() => {
    void message.path;
    copiedPath = null;
    openingPath = null;
    attachmentError = null;
    sessionError = null;
    composing = null;
    opError = null;
    seenOverride = null;
    showDetails = false;
    viewMode = 'html';
    allowOnce = false;
    trustOverride = null;
    trustError = null;
  });

  // Ops context: the message's indexed id is its frontmatter `id`; the
  // source folder is the list the user opened it from; the archive and trash
  // destinations are the ACCOUNT'S configured names (Gmail: "[Gmail]/All
  // Mail", "[Gmail]/Trash"), never hardcoded "Archive"/"Trash".
  const msgId = $derived(typeof frontmatter.id === 'string' ? frontmatter.id : null);
  const currentFolder = $derived(mailStore.selectedFolder);
  const archiveFolder = $derived(mailStore.selectedStatus?.folders?.archive ?? null);
  const trashFolder = $derived(trashTarget(mailStore.selectedStatus, currentFolder));
  // Everywhere else this message could be filed by hand — the mirrored
  // folders minus this one and the held ones.
  const folderTargets = $derived(moveTargets(mailStore.folders, currentFolder));
  const flagged = $derived(
    typeof frontmatter.flags === 'string' && frontmatter.flags.includes('F')
  );
  // Read state, as the mailbox last reported it, and as this pane now knows
  // it to be (spec E: the maildir `S` letter is the whole read model —
  // Valea keeps no read-tracking of its own).
  const fetchedSeen = $derived(
    messageSeen({ flags: typeof frontmatter.flags === 'string' ? frontmatter.flags : null })
  );
  const seen = $derived(seenOverride ?? fetchedSeen);
  const canArchive = $derived(
    msgId !== null && currentFolder !== null && archiveFolder !== null && currentFolder !== archiveFolder
  );
  // `trashTarget` has already ruled out an unconfigured trash and a message
  // that is in it, so only the op's own two ingredients are left to check.
  const canTrash = $derived(msgId !== null && currentFolder !== null && trashFolder !== null);

  // -- thread strip (Task 11) ------------------------------------------------
  //
  // The open message's conversation as compact jump rows above the body,
  // oldest first — `get_mail_thread` reads across FOLDERS, so the Sent copy
  // of a reply sits in the same strip as the message it answered, and a row
  // whose folder isn't the one being listed says so.
  //
  // Only ever rendered for a real conversation (more than one message):
  // a strip that jumps nowhere is chrome. Nothing here degrades the read
  // pane — a thread that failed to load, or a message whose conversation
  // this side can't name, simply shows no strip (see `MailStore.loadThread`).
  const threadMessages = $derived(mailStore.threadMessages);
  const showThread = $derived(threadMessages.length > 1);

  // `mailStore.messages` is a real dependency, not a formality: the strip's
  // thread key is looked up in the folder listing, and a deep-linked message
  // can open before that listing lands — so its arrival is a reason to look
  // again. The repeat runs a push causes are settled inside `loadThread`
  // without an RPC once the strip holds the open message.
  //
  // `untrack` around the call is load-bearing (the same trap the route's
  // selection effect documents): `loadThread` reads `threadMessages`
  // synchronously and writes it after its await, so a tracked call would
  // re-trigger this effect with its own result and fetch in a loop.
  $effect(() => {
    const id = msgId;
    void mailStore.messages;
    untrack(() => void mailStore.loadThread(id));
  });

  /**
   * The msg_id the auto-mark has already run for — or that a manual "Mark
   * unread" has suppressed it for. Deliberately a plain `let`, not `$state`:
   * the effect below both reads and writes it, and nothing renders from it.
   * The stored id IS the expiry — a different message can never match it, so
   * opening one is what lifts a suppression, exactly as intended.
   */
  let autoMarkedId: string | null = null;

  // Opening a message marks it read, once. Fire-and-forget by design: a
  // message the reader is looking at that still counts as unread is a lie
  // worth correcting, but a rejected correction is not worth an error banner
  // over something they never asked for — unlike archive/flag/mark below,
  // which are explicit actions and keep their error surfacing. The id guard
  // is what makes it once-per-open: `applyOps`' refetches, a folder switch,
  // or any other re-run of this effect must not fire a second op.
  $effect(() => {
    const id = msgId;
    const folder = currentFolder;
    if (!id || !folder || fetchedSeen || autoMarkedId === id) return;
    autoMarkedId = id;
    void autoMarkRead(id, folder);
  });

  /**
   * The auto-mark's own apply path, deliberately NOT `runOp`: this op must
   * not take the busy flag (it would disable the whole action row for the
   * duration of every open) and its rejection must stay silent. The `seen`
   * flip is applied only on acceptance, so a mark that didn't land leaves
   * the pane telling the truth — still unread, and manually markable. It
   * also defers to any explicit decision taken while it was in flight (a
   * "Mark unread" clicked during the round-trip owns the flag, not this).
   */
  async function autoMarkRead(id: string, folder: string): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!account) return;

    const results = await mailStore.applyOps(account, [markReadOp(id, folder)], workspaceStore.generation ?? 0);
    if (opOutcome(results) !== null) return;
    if (seenOverride === null) seenOverride = true;
  }

  /**
   * The failure copy for a one-op batch's results, or `null` when the op
   * came back `"ok"` — the ONE place both apply paths decide what succeeded.
   * A missing entry is not an acceptance: `mail_apply_ops`' frozen shape
   * returns exactly one result per op (a batch the Engine couldn't run at
   * all is still reported per-op), so its absence is an anomaly, and the
   * unrecognized status falls through to the rejection copy rather than
   * navigating the reader away from a message nothing confirmed moving.
   */
  function opOutcome(results: { result: string; reason: string | null }[]): string | null {
    const first = results[0];
    return opResultMessage(first?.result ?? 'missing', first?.reason ?? null);
  }

  /** Applies one op through the store; resolves `true` when it was accepted (a failure is left on `opError`). */
  async function runOp(op: Record<string, unknown>, afterArchive: boolean): Promise<boolean> {
    const account = mailStore.selectedAccount;
    if (!account) return false;

    opBusy = true;
    opError = null;
    const results = await mailStore.applyOps(account, [op], workspaceStore.generation ?? 0);
    opBusy = false;

    const failure = opOutcome(results);
    if (failure) {
      opError = failure;
      return false;
    }
    if (afterArchive) void goto('/mail');
    return true;
  }

  function archive(): void {
    if (!msgId || !currentFolder || !archiveFolder) return;
    void runOp({ op: 'move', msg_id: msgId, from: currentFolder, to: archiveFolder }, true);
  }

  /**
   * "Delete" — a move into the account's trash folder, and nothing more.
   * Deliberately unconfirmed: Valea never expunges, so this destroys
   * nothing; the message is one "Move to…" away from wherever it was, from
   * here or from any other mail client.
   */
  function trash(): void {
    if (!msgId || !currentFolder || !trashFolder) return;
    void runOp({ op: 'move', msg_id: msgId, from: currentFolder, to: trashFolder }, true);
  }

  /** "Move to…" — the same op as archive/delete, with the picked folder as its destination. */
  function moveTo(folder: string): void {
    if (!msgId || !currentFolder) return;
    void runOp({ op: 'move', msg_id: msgId, from: currentFolder, to: folder }, true);
  }

  /**
   * The explicit read/unread action — same `runOp` path as archive/flag, so
   * a rejection is reported here rather than swallowed. Marking unread also
   * parks this message in `autoMarkedId`: without that the auto-mark above
   * would undo the click the next time anything re-runs its effect.
   */
  async function toggleSeen(): Promise<void> {
    const id = msgId;
    const folder = currentFolder;
    if (!id || !folder) return;

    const next = !seen;
    if (!next) autoMarkedId = id;
    const op = next ? markReadOp(id, folder) : markUnreadOp(id, folder);
    if (await runOp(op, false)) seenOverride = next;
  }

  function toggleFlag(): void {
    if (!msgId || !currentFolder) return;
    const op = flagged
      ? { op: 'flag', msg_id: msgId, folder: currentFolder, add: [], remove: ['F'] }
      : { op: 'flag', msg_id: msgId, folder: currentFolder, add: ['F'], remove: [] };
    void runOp(op, false);
  }

  /**
   * Chip click = OPEN the attachment — a new tab in the browser, the OS
   * browser on desktop, both via `prepareExternalOpen`.
   *
   * The URL is `/files/raw` addressed by the account's synthetic
   * `mail-<account>` mount (`mailAttachmentTarget` re-addresses the
   * frontmatter's workspace-relative path; the backend confines a mail mount
   * to `views/attachments/` and re-contains it there). It carries a
   * short-lived one-file `ticket` rather than the control-token header,
   * because the fetch is made by a tab or by another process entirely and
   * neither can send headers — see `api.fileTicket`.
   *
   * `prepareExternalOpen()` runs FIRST, while the click is still on the
   * stack, so the browser tab is reserved before the ticket round-trip a
   * popup blocker would otherwise judge us for.
   */
  async function openAttachment(path: string): Promise<void> {
    if (openingPath !== null) return;

    const target = mailAttachmentTarget(path);
    if (!target) {
      attachmentError = 'This attachment is not where the mailbox stores attachments.';
      return;
    }

    const finishOpen = prepareExternalOpen();
    openingPath = path;
    attachmentError = null;

    const result = await api.fileTicket(target.mountKey, target.path);
    openingPath = null;

    if (!result.ok) {
      attachmentError = 'Could not open the attachment.';
      finishOpen(null);
      return;
    }

    finishOpen(rawFileOpenUrl(target.mountKey, target.path, result.data, window.location.origin));
  }

  async function copyAttachmentPath(path: string): Promise<void> {
    try {
      await navigator.clipboard.writeText(path);
      copiedPath = path;
      setTimeout(() => {
        if (copiedPath === path) copiedPath = null;
      }, 1500);
    } catch {
      // Clipboard access can fail (permissions, insecure context) — a
      // convenience action failing silently beats a scary error dialog.
    }
  }

  /**
   * Reply / Reply-all / Forward — the composer's entry points off an open
   * message. The prefill (recipients, `Re:`/`Fwd:` subject, threading hint,
   * quoted or forwarded body) is computed by `compose.ts` and handed over
   * IN MEMORY: a quoted message body has no business in a URL, so this
   * follows `initial-prompt.ts`'s one-shot stash rather than query params.
   *
   * The one thing this awaits is the account's own address — reply-all's
   * whole job is to take the user back out of the recipient list, and the
   * sending identity (`smtp.from`) is the only address that can honestly do
   * that. `mailStore.ownAddress` caches it per account; a failed lookup
   * resolves `null`, which prefills one address too many rather than
   * dropping someone.
   */
  async function startCompose(mode: ComposeMode): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!account || composing) return;

    composing = mode;
    const own = await mailStore.ownAddress(account);
    composing = null;

    setComposePrefill(account, replyPrefill({ frontmatter: message.frontmatter, body: message.body }, own, mode));
    void goto(composeHref(account, null));
  }

  /**
   * Why the button cannot start a session, in the order the user can act on.
   * A message with no file on disk was already refused — silently, by a bare
   * `disabled` — so it joins the reasons rather than staying a mystery.
   */
  const sessionRefusal = $derived(
    !message.path ? 'This message has no file on disk to open a session about' : sessionBesideRefusal
  );

  /**
   * "Start a session about this message" (Spec D §B/§E) — mints a session
   * granted read access to exactly this message file (`opts.input`, a
   * workspace locator — mail messages live under `sources/mail/`, outside
   * any ICM's own tree, unlike Knowledge's `contextDoc` grant), stashes the
   * opening prompt under the new session id, and hands the id to the host,
   * which opens it BESIDE this message. Mount selection mirrors
   * `routes/chat/+page.svelte`'s `primaryMountKey()` fallback: the first
   * enabled, non-degraded mount (`icmStore.groups` is already filtered to
   * exactly that set — see `icm.svelte.ts`).
   *
   * The refusal is re-checked here and not merely rendered: the button is
   * `aria-disabled`, which leaves it clickable on purpose, and a session
   * created for a pane that cannot open is a real session left nowhere.
   */
  async function startSession(): Promise<void> {
    const account = mailStore.selectedAccount;
    if (sessionRefusal || !message.path || !account) return;
    starting = true;
    sessionError = null;
    try {
      const mountKey = icmStore.groups[0]?.mount;
      if (!mountKey) {
        sessionError = 'No enabled project can host the session. Enable one in the sidebar.';
        return;
      }
      // The session is opted into the whole account's mail mount (T14
      // `includeMounts`) on top of the exact-file input grant — the agent can
      // read the mailbox views and write ops/drafts. It cannot send: a draft
      // it writes goes out only when the user pushes or sends it from the
      // Drafts panel (spec G §Invariant rewrite).
      const mailMountKey = `mail-${account}`;
      const result = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0, {
        input: { kind: 'workspace', path: message.path },
        includeMounts: [mailMountKey]
      });
      if (!result.ok) {
        sessionError =
          result.error === 'input_unavailable'
            ? "This message file isn't available on disk anymore."
            : `Couldn't start the session (${result.error}).`;
        return;
      }
      const data = result.data as { id: string; inputPath: string | null };
      setInitialPrompt(data.id, messageSessionPrompt(data.inputPath ?? message.path, mailMountKey));
      onSessionBeside(data.id);
    } finally {
      starting = false;
    }
  }
</script>

<article class="flex flex-col gap-6">
  <header class="border-paper-hairline flex flex-col gap-2.5 border-b pb-5">
    <div class="flex flex-wrap items-start justify-between gap-x-4 gap-y-2">
      <h1 class="font-display text-ink-heading min-w-0 flex-1 basis-64 text-[22px] leading-snug font-medium">
        {subject}
      </h1>
      <!-- Compact icon toolbar: answer actions | mailbox ops | overflow.
           Everything here also lives somewhere honest — Reply and friends in
           the bottom action bar, the rest behind the ⋯ menu — so icon-only
           chrome never becomes the sole path to an action's words. -->
      <div
        class="border-paper-border bg-paper-panel flex shrink-0 items-center gap-0.5 rounded-lg border p-0.5"
        role="toolbar"
        aria-label="Message actions"
      >
        <button
          type="button"
          class={toolbarBtn}
          title="Reply"
          aria-label="Reply"
          disabled={composing !== null}
          onclick={() => void startCompose('reply')}
        >
          <ReplyIcon class="size-4" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          class={toolbarBtn}
          title="Reply all"
          aria-label="Reply all"
          disabled={composing !== null}
          onclick={() => void startCompose('replyAll')}
        >
          <ReplyAll class="size-4" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          class={toolbarBtn}
          title="Forward"
          aria-label="Forward"
          disabled={composing !== null}
          onclick={() => void startCompose('forward')}
        >
          <ForwardIcon class="size-4" strokeWidth={1.5} />
        </button>
        {#if canArchive || (msgId && currentFolder)}
          <div class="bg-paper-chip-border mx-0.5 h-5 w-px" aria-hidden="true"></div>
        {/if}
        {#if canArchive}
          <button
            type="button"
            class={toolbarBtn}
            title="Archive"
            aria-label="Archive"
            disabled={opBusy}
            onclick={() => archive()}
          >
            <Archive class="size-4" strokeWidth={1.5} />
          </button>
        {/if}
        {#if msgId && currentFolder}
          <button
            type="button"
            class={toolbarBtn}
            title={seen ? 'Mark unread' : 'Mark read'}
            aria-label={seen ? 'Mark unread' : 'Mark read'}
            disabled={opBusy}
            onclick={() => void toggleSeen()}
          >
            {#if seen}
              <MailIcon class="size-4" strokeWidth={1.5} />
            {:else}
              <MailOpen class="size-4" strokeWidth={1.5} />
            {/if}
          </button>
        {/if}
        <div class="bg-paper-chip-border mx-0.5 h-5 w-px" aria-hidden="true"></div>
        <DropdownMenu.Root>
          <DropdownMenu.Trigger>
            {#snippet child({ props })}
              <button
                type="button"
                {...props}
                class="{toolbarBtn} data-[state=open]:bg-paper-pill data-[state=open]:text-ink-heading"
                title="More actions"
                aria-label="More actions"
              >
                <Ellipsis class="size-4" strokeWidth={1.5} />
              </button>
            {/snippet}
          </DropdownMenu.Trigger>
          <DropdownMenu.Content align="end" class="w-52">
            {#if msgId && currentFolder}
              {#if folderTargets.length > 0}
                <DropdownMenu.Sub>
                  <DropdownMenu.SubTrigger disabled={opBusy}>
                    <FolderInput class="size-3.5" strokeWidth={1.5} />
                    Move to
                  </DropdownMenu.SubTrigger>
                  <DropdownMenu.SubContent class="max-h-80 w-56 overflow-y-auto">
                    {#each folderTargets as folder (folder.name)}
                      <DropdownMenu.Item onSelect={() => moveTo(folder.name)}>
                        <span class="min-w-0 flex-1 truncate">{folder.name}</span>
                        <span class="text-ink-meta text-[11px] tabular-nums">{folder.messageCount}</span>
                      </DropdownMenu.Item>
                    {/each}
                  </DropdownMenu.SubContent>
                </DropdownMenu.Sub>
              {/if}
              <DropdownMenu.Item disabled={opBusy} onSelect={() => toggleFlag()}>
                <Flag class="size-3.5" strokeWidth={1.5} />
                {flagged ? 'Unflag' : 'Flag'}
              </DropdownMenu.Item>
            {/if}
            {#if canTrash}
              <DropdownMenu.Item variant="destructive" disabled={opBusy} onSelect={() => trash()}>
                <Trash2 class="size-3.5" strokeWidth={1.5} />
                Delete
              </DropdownMenu.Item>
            {/if}
            {#if message.html !== null}
              <DropdownMenu.Separator />
              <DropdownMenu.Label>View as</DropdownMenu.Label>
              <DropdownMenu.Item onSelect={() => (viewMode = 'html')}>
                <span class="flex size-3.5 items-center justify-center" aria-hidden="true">
                  {#if viewMode === 'html'}<Check class="size-3.5" strokeWidth={2} />{/if}
                </span>
                Formatted
              </DropdownMenu.Item>
              <DropdownMenu.Item onSelect={() => (viewMode = 'text')}>
                <span class="flex size-3.5 items-center justify-center" aria-hidden="true">
                  {#if viewMode === 'text'}<Check class="size-3.5" strokeWidth={2} />{/if}
                </span>
                Plain text
              </DropdownMenu.Item>
            {/if}
          </DropdownMenu.Content>
        </DropdownMenu.Root>
      </div>
    </div>
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5">
      {#if fromName}
        <span
          class="bg-paper-pill text-ink-secondary inline-flex items-center rounded-full px-2.5 py-0.5 text-[12px] font-semibold"
        >
          {fromName}
        </span>
      {/if}
      <span class="text-ink-secondary min-w-0 truncate text-[12.5px]">{metaLine}</span>
      {#if to}
        <span class="text-ink-meta min-w-0 truncate text-[12px]">to {to}</span>
      {/if}
      <span class="min-w-4 flex-1" aria-hidden="true"></span>
      <button
        type="button"
        class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex shrink-0 items-center gap-1 rounded-md px-1.5 py-0.5 text-[12px] transition-colors"
        aria-expanded={showDetails}
        onclick={() => (showDetails = !showDetails)}
      >
        Details
        <ChevronDown
          class={['size-3 transition-transform', showDetails && 'rotate-180']}
          strokeWidth={1.5}
          aria-hidden="true"
        />
      </button>
    </div>
    {#if showDetails}
      <dl
        class="border-paper-border bg-paper-panel grid grid-cols-[auto_1fr] gap-x-4 gap-y-1 rounded-lg border px-3.5 py-2.5 text-[11.5px]"
      >
        <dt class="text-ink-meta">Source path</dt>
        <dd class="text-ink-secondary min-w-0 font-mono text-[11px] break-all">{message.path}</dd>
        {#if detailFolders}
          <dt class="text-ink-meta">Folder</dt>
          <dd class="text-ink-secondary min-w-0">{detailFolders}</dd>
        {/if}
        {#if detailFlags}
          <dt class="text-ink-meta">Flags</dt>
          <dd class="text-ink-secondary min-w-0 font-mono text-[11px]">{detailFlags}</dd>
        {/if}
      </dl>
    {/if}
    {#if opError}
      <p class="text-warn-ink text-[12px]" role="alert">{opError}</p>
    {/if}
  </header>

  {#if showThread}
    {@const account = mailStore.selectedAccount ?? ''}
    <nav class="border-paper-border bg-paper-card -mt-2 flex flex-col rounded-lg border" aria-label="Conversation">
      <p class="text-overline border-paper-hairline border-b px-3 py-1.5">
        Conversation · {threadMessages.length} messages
      </p>
      <!-- Capped rather than unbounded: a long thread must not push the
           message the reader opened off the screen. -->
      <ul class="divide-paper-hairline max-h-[172px] divide-y overflow-y-auto">
        {#each threadMessages as entry (entry.msgId)}
          {@const current = entry.msgId === msgId}
          <li>
            <a
              href={messageHref(account, entry.msgId)}
              aria-current={current ? 'true' : undefined}
              class="hover:bg-paper-pill flex items-baseline gap-2 border-l-[3px] px-2.5 py-1.5 transition-colors"
              class:border-act={current}
              class:border-transparent={!current}
              class:bg-paper-pill={current}
            >
              <!-- The CURRENT row reads its dot from this pane's own `seen`,
                   never from the fetched strip row: opening a message
                   auto-marks it read (and "Mark unread" flips it back), and
                   neither refetches the strip — it is deliberately kept
                   across the jumps it exists for. Without this, the message
                   you are reading shows a read header above an unread dot
                   for itself, indefinitely. Every OTHER row is the strip's
                   own flags, which nothing in this pane has moved. -->
              {#if current ? !seen : !messageSeen(entry)}
                <span class="bg-act size-1.5 shrink-0 self-center rounded-full" title="Unread" aria-label="Unread"
                ></span>
              {/if}
              <span class="min-w-0 flex-1 truncate text-[12.5px]" class:text-ink-heading={current} class:text-ink-body={!current}>
                {fromLabel(entry)}
              </span>
              {#if entry.folder && entry.folder !== currentFolder}
                <span class="bg-paper-track text-ink-meta shrink-0 rounded-full px-1.5 text-[10.5px]">
                  {entry.folder}
                </span>
              {/if}
              <span class="text-ink-meta shrink-0 text-[11px]">{relativeTime(entry.date)}</span>
            </a>
          </li>
        {/each}
      </ul>
    </nav>
  {/if}

  {#if showHtml && message.html !== null}
    {#if message.externalContent && !allowRemote}
      <!-- Fail-closed: remote loads (images, tracking pixels) stay blocked
           until the reader explicitly allows them — once, or by trusting
           the sender from here on. -->
      <div
        class="border-paper-border bg-paper-card flex flex-wrap items-center gap-x-3 gap-y-2 rounded-lg border px-3.5 py-2.5"
        role="note"
      >
        <p class="text-ink-body min-w-0 flex-1 text-[12.5px]">
          Remote images are hidden to protect your privacy.
        </p>
        <div class="flex shrink-0 items-center gap-1.5">
          <Button type="button" variant="outline" size="sm" onclick={() => (allowOnce = true)}>Load once</Button>
          {#if fromEmail}
            <Button type="button" variant="ghost" size="sm" disabled={trustBusy} onclick={() => void setTrust(true)}>
              Always trust {fromEmail}
            </Button>
          {/if}
        </div>
      </div>
    {:else if message.externalContent && trusted && fromEmail}
      <p class="text-ink-meta text-[11.5px]">
        Remote content loads — {fromEmail} is trusted.
        <button
          type="button"
          class="hover:text-ink-heading underline decoration-dotted underline-offset-2 transition-colors"
          disabled={trustBusy}
          onclick={() => void setTrust(false)}
        >
          Stop trusting
        </button>
      </p>
    {/if}
    {#if trustError}
      <p class="text-warn-ink text-[12px]" role="alert">{trustError}</p>
    {/if}
    <HtmlMailView html={message.html} {allowRemote} />
  {:else}
    <!-- The same white reading card the HTML view's iframe provides, so the
         two views of one message share a surface.
         The `{#each}` sits tight against the text on purpose: inside
         `whitespace-pre-wrap` any newline or indent between these tags would
         render as literal whitespace in the message. -->
    <div class="border-paper-border bg-paper-card rounded-xl border px-5 py-4">
      <p
        class="text-ink-body max-w-[620px] text-[14px] leading-[1.65] whitespace-pre-wrap"
      >{#each bodySegments as segment, i (i)}{#if segment.href}{@const href = segment.href}<a
            {href}
            target="_blank"
            rel="noopener noreferrer"
            onclick={(event) => onLinkClick(event, href)}
            class="text-ink-heading decoration-paper-button-border underline underline-offset-2 hover:decoration-ink-secondary"
          >{segment.text}</a>{:else}{segment.text}{/if}{/each}</p>
    </div>
  {/if}

  {#if attachments.length > 0}
    <div>
      <p class="text-overline mb-2">Attachments</p>
      <div class="flex flex-wrap items-center gap-1.5">
        {#each attachments as attachment (attachment.path)}
          <!-- The chip body OPENS the attachment (the whole point of a
               chip); download and copy-path ride along as small icon
               affordances — the download icon is the same open (the OS
               browser is where a mail attachment is saved from). -->
          <span
            class="border-paper-border bg-paper-card text-ink-secondary inline-flex items-center gap-0.5 rounded-lg border py-1 pr-1 pl-2.5 text-[12px]"
          >
            <button
              type="button"
              class="hover:text-ink-heading inline-flex min-w-0 items-center gap-1.5 transition-colors disabled:opacity-60"
              disabled={openingPath !== null}
              title="Open {attachment.filename}"
              onclick={() => void openAttachment(attachment.path)}
            >
              <Paperclip class="text-ink-meta size-3.5 shrink-0" aria-hidden="true" strokeWidth={1.5} />
              <span class="text-ink-heading max-w-56 truncate font-medium">{attachment.filename}</span>
              <span class="text-ink-meta shrink-0">{formatBytes(attachment.bytes)}</span>
              {#if openingPath === attachment.path}
                <span class="text-ink-meta shrink-0">Opening…</span>
              {/if}
            </button>
            <button
              type="button"
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading ml-1 flex size-7 shrink-0 items-center justify-center rounded-md transition-colors disabled:pointer-events-none disabled:opacity-50"
              disabled={openingPath !== null}
              title="Download {attachment.filename}"
              aria-label="Download {attachment.filename}"
              onclick={() => void openAttachment(attachment.path)}
            >
              <Download class="size-3.5" aria-hidden="true" strokeWidth={1.5} />
            </button>
            <button
              type="button"
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex size-7 shrink-0 items-center justify-center rounded-md transition-colors"
              title="Copy path"
              aria-label="Copy the workspace path to {attachment.filename}"
              onclick={() => void copyAttachmentPath(attachment.path)}
            >
              {#if copiedPath === attachment.path}
                <Check class="text-act size-3.5" aria-hidden="true" strokeWidth={2} />
              {:else}
                <Copy class="size-3.5" aria-hidden="true" strokeWidth={1.5} />
              {/if}
            </button>
          </span>
        {/each}
      </div>
      {#if attachmentError}
        <p class="text-warn-ink mt-2 text-[12px]" role="alert">{attachmentError}</p>
      {/if}
    </div>
  {/if}

  <div class="border-paper-hairline flex flex-col gap-2 border-t pt-4">
    <!-- Reply-only by design: the mailbox ops (archive, move, flag, read
         state, delete) live in the header toolbar and its ⋯ menu, so this
         bar can never wrap into the crowded strip it used to become on a
         narrow pane. The session action keeps its own right-hand corner. -->
    <div class="flex flex-wrap items-center gap-2.5">
      <Button type="button" disabled={composing !== null} onclick={() => void startCompose('reply')}>
        <ReplyIcon class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
        {composing === 'reply' ? 'Opening…' : 'Reply'}
      </Button>
      <Button
        type="button"
        variant="outline"
        disabled={composing !== null}
        onclick={() => void startCompose('replyAll')}
      >
        {composing === 'replyAll' ? 'Opening…' : 'Reply all'}
      </Button>
      <Button
        type="button"
        variant="outline"
        disabled={composing !== null}
        onclick={() => void startCompose('forward')}
      >
        {composing === 'forward' ? 'Opening…' : 'Forward'}
      </Button>
<!-- `aria-disabled`, not `disabled`, whenever there is a REASON: a truly
           disabled button takes no pointer events, so its `title` never
           appears, and it leaves the tab order, so a keyboard user can never
           reach the reason either. `disabled` is kept for `starting`, which is
           transient and says so in the label. -->
      <Button
        type="button"
        variant="outline"
        class={['ms-auto', sessionRefusal ? 'cursor-default opacity-60' : '']}
        disabled={starting}
        aria-disabled={sessionRefusal ? 'true' : undefined}
        title={sessionRefusal ?? 'Start a session beside this message'}
        aria-label={sessionRefusal
          ? `Start a session beside this message — unavailable: ${sessionRefusal.toLowerCase()}`
          : 'Start a session beside this message'}
        onclick={() => void startSession()}
      >
        <MessageSquarePlus class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
        {starting ? 'Starting…' : 'Start a session'}
      </Button>
    </div>
    {#if sessionError}<p class="text-warn-ink text-[12.5px]" role="alert">{sessionError}</p>{/if}
  </div>
</article>
