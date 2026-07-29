<script lang="ts">
  // Read pane for a selected message, per the cockpit mail screen: subject
  // as the Newsreader page headline, one meta row under it (sender-name
  // pill · address · date, and the message's workspace file path in mono
  // right-aligned — the §1 ownership signature), hairline, then the body as
  // plain preformatted TEXT directly on the reading surface
  // (`white-space: pre-wrap`, NOT markdown-rendered, NEVER `{@html}` —
  // untrusted mail content, same inert-interpolation posture elsewhere in
  // this app), attachment chips, then a closing hairline with a status
  // affordance underneath.
  //
  // Spec D deletion wave: the "Run triage" workflow action that used to
  // live in the actions strip below the hairline is gone along with the
  // whole queue/workflow subsystem. Task 11 replaces it with "Start a
  // session about this message" — same exact-read-grant + one-shot opening
  // prompt pattern as Knowledge's "Start a session with this page"
  // (`EntryMenu.svelte`'s `startSessionWithEntry`), just keyed off
  // `message.path` and `contextDoc` swapped for `input` (a workspace
  // locator, not an ICM one — mail messages live outside any ICM's tree).
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { SegmentedControl } from '$lib/components/shell';
  import HtmlMailView from './HtmlMailView.svelte';
  import { api } from '$lib/api/client';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { setInitialPrompt } from '$lib/stores/initial-prompt';
  import {
    addressEmail,
    addressListLabel,
    addressName,
    attachmentsFromFrontmatter,
    folderFlagsLine,
    formatBytes,
    formatDateTime,
    markReadOp,
    markUnreadOp,
    messageSeen,
    messageSessionPrompt,
    opResultMessage,
    subjectLabel,
    type RawAddress
  } from './mail-shapes';
  import type { MailMessageDetail } from '$lib/stores/mail.svelte';

  let { message }: { message: MailMessageDetail } = $props();

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
  const placement = $derived(folderFlagsLine(frontmatter));
  const attachments = $derived(attachmentsFromFrontmatter(message.frontmatter));

  let copiedPath: string | null = $state(null);
  let starting = $state(false);
  let sessionError = $state<string | null>(null);
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
    sessionError = null;
    opError = null;
    seenOverride = null;
    viewMode = 'html';
    allowOnce = false;
    trustOverride = null;
    trustError = null;
  });

  // Ops context: the message's indexed id is its frontmatter `id`; the
  // source folder is the list the user opened it from; the archive
  // destination is the ACCOUNT'S configured name (Gmail: "[Gmail]/All
  // Mail"), never a hardcoded "Archive".
  const msgId = $derived(typeof frontmatter.id === 'string' ? frontmatter.id : null);
  const currentFolder = $derived(mailStore.selectedFolder);
  const archiveFolder = $derived(mailStore.selectedStatus?.folders?.archive ?? null);
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
    const first = results[0];
    if (first && opResultMessage(first.result, first.reason) !== null) return;
    if (seenOverride === null) seenOverride = true;
  }

  /** Applies one op through the store; resolves `true` when it was accepted (a failure is left on `opError`). */
  async function runOp(op: Record<string, unknown>, afterArchive: boolean): Promise<boolean> {
    const account = mailStore.selectedAccount;
    if (!account) return false;

    opBusy = true;
    opError = null;
    const results = await mailStore.applyOps(account, [op], workspaceStore.generation ?? 0);
    opBusy = false;

    const first = results[0];
    const failure = first ? opResultMessage(first.result, first.reason) : null;
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
   * "Start a session about this message" (Spec D §B/§E) — mints a session
   * granted read access to exactly this message file (`opts.input`, a
   * workspace locator — mail messages live under `sources/mail/`, outside
   * any ICM's own tree, unlike Knowledge's `contextDoc` grant), stashes the
   * opening prompt under the new session id, and navigates there. Mount
   * selection mirrors `routes/chat/+page.svelte`'s `primaryMountKey()`
   * fallback: the first enabled, non-degraded mount (`icmStore.groups` is
   * already filtered to exactly that set — see `icm.svelte.ts`).
   */
  async function startSession(): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!message.path || !account) return;
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
      void goto(`/chat?session=${data.id}`);
    } finally {
      starting = false;
    }
  }
</script>

<article class="flex flex-col gap-6">
  <header class="border-paper-hairline flex flex-col gap-2.5 border-b pb-5">
    <h1 class="font-display text-ink-heading text-[22px] leading-snug font-medium">{subject}</h1>
    <div class="flex flex-wrap items-center gap-x-3 gap-y-1.5">
      {#if fromName}
        <span
          class="bg-paper-pill text-ink-secondary inline-flex items-center rounded-full px-2.5 py-0.5 text-[12px] font-semibold"
        >
          {fromName}
        </span>
      {/if}
      <span class="text-ink-secondary min-w-0 truncate text-[12.5px]">{metaLine}</span>
      <span class="min-w-4 flex-1" aria-hidden="true"></span>
      <span class="text-ink-meta max-w-full truncate font-mono text-[11px]">{message.path}</span>
    </div>
    {#if to}
      <p class="text-ink-meta text-[12px]">To {to}</p>
    {/if}
    {#if placement}
      <p class="text-ink-meta text-[11.5px]">{placement}</p>
    {/if}
  </header>

  {#if message.html !== null}
    <div class="-mt-2 flex items-center justify-end">
      <SegmentedControl
        label="Message view"
        value={viewMode}
        options={[
          { value: 'html', label: 'Formatted' },
          { value: 'text', label: 'Plain text' }
        ]}
        onChange={(v) => (viewMode = v as 'html' | 'text')}
      />
    </div>
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
    <p class="text-ink-body max-w-[620px] text-[14px] leading-[1.65] whitespace-pre-wrap">{message.body}</p>
  {/if}

  {#if attachments.length > 0}
    <div>
      <p class="text-overline mb-2">Attachments</p>
      <div class="flex flex-wrap items-center gap-1.5">
        {#each attachments as attachment (attachment.path)}
          <button
            type="button"
            class="border-paper-chip-border bg-paper-track text-ink-secondary hover:bg-paper-pill inline-flex items-center gap-1.5 rounded-full border px-2 py-0.5 text-[11.5px] transition-colors"
            onclick={() => void copyAttachmentPath(attachment.path)}
          >
            <Paperclip class="size-3" aria-hidden="true" strokeWidth={1.5} />
            {attachment.filename}
            <span class="text-ink-meta">· {formatBytes(attachment.bytes)}</span>
            {#if copiedPath === attachment.path}
              <span class="text-act font-semibold">Copied</span>
            {/if}
          </button>
        {/each}
      </div>
    </div>
  {/if}

  <div class="border-paper-hairline flex flex-col gap-2 border-t pt-4">
    <div class="flex flex-wrap items-center gap-2.5">
      <Button type="button" disabled={starting || !message.path} onclick={() => void startSession()}>
        Start a session about this message
      </Button>
      {#if canArchive}
        <Button type="button" variant="outline" disabled={opBusy} onclick={() => archive()}>Archive</Button>
      {/if}
      {#if msgId && currentFolder}
        <Button type="button" variant="ghost" disabled={opBusy} onclick={() => toggleFlag()}>
          {flagged ? 'Unflag' : 'Flag'}
        </Button>
        <Button type="button" variant="ghost" disabled={opBusy} onclick={() => void toggleSeen()}>
          {seen ? 'Mark unread' : 'Mark read'}
        </Button>
      {/if}
    </div>
    {#if sessionError}<p class="text-warn-ink text-[12.5px]" role="alert">{sessionError}</p>{/if}
    {#if opError}<p class="text-warn-ink text-[12.5px]" role="alert">{opError}</p>{/if}
  </div>
</article>
