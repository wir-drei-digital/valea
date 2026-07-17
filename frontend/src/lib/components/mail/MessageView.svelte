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
  // (`EntryMenu.svelte`'s `startSessionWithPage`), just keyed off
  // `message.path` and `contextDoc` swapped for `input` (a workspace
  // locator, not an ICM one — mail messages live outside any ICM's tree).
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
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

  // A different message was opened — drop this session's local "just
  // copied a path" affordance and any stale session-start/op error so none
  // bleeds into the newly-selected message's view.
  $effect(() => {
    void message.path;
    copiedPath = null;
    sessionError = null;
    opError = null;
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
  const canArchive = $derived(
    msgId !== null && currentFolder !== null && archiveFolder !== null && currentFolder !== archiveFolder
  );

  async function runOp(op: Record<string, unknown>, afterArchive: boolean): Promise<void> {
    const account = mailStore.selectedAccount;
    if (!account) return;

    opBusy = true;
    opError = null;
    const results = await mailStore.applyOps(account, [op], workspaceStore.generation ?? 0);
    opBusy = false;

    const first = results[0];
    const failure = first ? opResultMessage(first.result, first.reason) : null;
    if (failure) {
      opError = failure;
      return;
    }
    if (afterArchive) void goto('/mail');
  }

  function archive(): void {
    if (!msgId || !currentFolder || !archiveFolder) return;
    void runOp({ op: 'move', msg_id: msgId, from: currentFolder, to: archiveFolder }, true);
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
        sessionError = 'No enabled ICM to host the session — enable one in the sidebar.';
        return;
      }
      // The session is opted into the whole account's mail mount (T14
      // `includeMounts`) on top of the exact-file input grant — the agent
      // can read the mailbox views and write ops/drafts, never send.
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

  <p class="text-ink-body max-w-[620px] text-[14px] leading-[1.65] whitespace-pre-wrap">{message.body}</p>

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
      {/if}
    </div>
    {#if sessionError}<p class="text-warn-ink text-[12.5px]" role="alert">{sessionError}</p>{/if}
    {#if opError}<p class="text-warn-ink text-[12.5px]" role="alert">{opError}</p>{/if}
  </div>
</article>
