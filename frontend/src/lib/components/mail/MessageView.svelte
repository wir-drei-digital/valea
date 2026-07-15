<script lang="ts">
  // Read pane for a selected message, per the cockpit mail screen: subject
  // as the Newsreader page headline, one meta row under it (sender-name
  // pill · address · date, and the message's workspace file path in mono
  // right-aligned — the §1 ownership signature), hairline, then the body as
  // plain preformatted TEXT directly on the reading surface
  // (`white-space: pre-wrap`, NOT markdown-rendered, NEVER `{@html}` —
  // untrusted mail content, same inert-interpolation posture as
  // `DraftReview`'s body), attachment chips, then either the "Run triage"
  // action or a neutral "Processed" badge behind a closing hairline.
  //
  // Run triage mirrors `today/InquiryTriageCard.svelte`'s in-flight/error
  // handling (`prepareReply`/`runWorkflowErrorMessage`) but deliberately
  // does NOT reconcile against `queueStore` the way that card does: the
  // card matches a pending queue item back to itself by `workflow` alone,
  // which only works because Today wires exactly one workflow to one seeded
  // input. Here, the SAME workflow (`New Inquiry Triage.md`) can run against
  // many different messages, and `list_queue_items`' summary carries no
  // `input`/message-path field to disambiguate one pending run from
  // another — so "Preparing…" is local, in-session state (matches the
  // brief's "disabled while in flight" wording), not a durable
  // reconstruction of an in-progress run across a reload. A reload mid-run
  // drops back to the plain button; the message's own `status` (flips to
  // "processed" once the run is approved and its mailbox ops land — see
  // `MailStore.handleMailboxOps`) is the durable, authoritative signal.
  //
  // Task 9.5: "Run triage" no longer trusts a single global seeded
  // workflow — `candidates` is EVERY enabled mount's own copy of
  // `New Inquiry Triage.md` (`triageCandidates`, `routes/mail/+page.svelte`).
  // Exactly one candidate runs directly (a workflow that already
  // identifies its ICM — spec §"Workspace-wide views"); more than one
  // opens a compact `DropdownMenu` picker instead of guessing which ICM
  // this message belongs to.
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import {
    addressEmail,
    addressListLabel,
    addressName,
    attachmentsFromFrontmatter,
    canRunTriage,
    formatBytes,
    formatDateTime,
    subjectLabel,
    type RawAddress
  } from './mail-shapes';
  import type { TriageCandidate } from './triage-workflows';
  import type { MailMessageDetail } from '$lib/stores/mail.svelte';

  let {
    message,
    // Task 9.5: every enabled mount's own "New Inquiry Triage.md" —
    // `routes/mail/+page.svelte`'s `triageCandidates(workflowsStore.list)`.
    // Empty means no enabled mount has one (the action stays hidden, never
    // a dead link — same degrade-gracefully posture the old single-workflow
    // props had).
    candidates = []
  }: {
    message: MailMessageDetail;
    candidates?: TriageCandidate[];
  } = $props();

  const frontmatter = $derived((message.frontmatter ?? {}) as Record<string, unknown>);
  const status = $derived(typeof frontmatter.status === 'string' ? frontmatter.status : null);
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
  const attachments = $derived(attachmentsFromFrontmatter(message.frontmatter));

  let running = $state(false);
  let preparing = $state(false);
  let runError: string | null = $state(null);
  let copiedPath: string | null = $state(null);

  // A different message was opened — drop this session's local "just ran
  // triage"/error affordances so they never bleed into the newly-selected
  // message's view.
  $effect(() => {
    void message.path;
    running = false;
    preparing = false;
    runError = null;
    copiedPath = null;
  });

  const canRun = $derived(canRunTriage(status, running || preparing));
  // Exactly one candidate runs directly — "a workflow that already
  // identifies one" (spec §"Workspace-wide views") needs no picker.
  // Zero hides the action entirely (unchanged from before this task);
  // more than one renders the `DropdownMenu` picker instead of this plain
  // button.
  const soleCandidate = $derived(candidates.length === 1 ? candidates[0] : null);

  async function runTriage(candidate: TriageCandidate): Promise<void> {
    running = true;
    runError = null;
    const result = await api.runWorkflow(
      candidate.mountKey,
      candidate.relativePath,
      { kind: 'workspace', path: message.path },
      workspaceStore.generation ?? 0
    );
    running = false;
    if (result.ok) {
      preparing = true;
    } else {
      runError = runWorkflowErrorMessage(result.error);
    }
  }

  function runWorkflowErrorMessage(code: string): string {
    switch (code) {
      case 'harness_unavailable':
        return 'The assistant harness is not ready yet.';
      case 'workflow_disabled':
        return 'This workflow is turned off.';
      case 'input_not_found':
        return 'This message could not be found.';
      case 'workspace_changed':
        return 'Your workspace changed. Reopen it and try again.';
      case 'workspace_not_open':
        return 'No workspace is open.';
      default:
        return 'Could not start the assistant. Please try again.';
    }
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

  <div class="border-paper-hairline flex flex-wrap items-center gap-2.5 border-t pt-4">
    {#if status === 'processed'}
      <span
        class="bg-paper-track text-ink-secondary inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
      >
        Processed
      </span>
    {:else if soleCandidate}
      <Button type="button" disabled={!canRun} onclick={() => void runTriage(soleCandidate)}>Run triage</Button>
      {#if preparing}
        <p class="text-ink-meta text-[12.5px]">Preparing… watch Today/Queue.</p>
      {/if}
      {#if runError}
        <p class="text-warn-ink text-[12.5px]" role="alert">{runError}</p>
      {/if}
    {:else if candidates.length > 1}
      <!-- Task 9.5: more than one enabled ICM carries this workflow — Mail
           must not guess which one this message belongs to (spec
           §"Workspace-wide views"), so "Run triage" opens a compact picker
           naming each candidate ICM instead of running one silently. -->
      <DropdownMenu.Root>
        <DropdownMenu.Trigger>
          {#snippet child({ props })}
            <Button type="button" disabled={!canRun} {...props}>
              Run triage
              <ChevronDown class="text-ink-meta" aria-hidden="true" />
            </Button>
          {/snippet}
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="start">
          {#each candidates as candidate (candidate.mountKey)}
            <DropdownMenu.Item onSelect={() => void runTriage(candidate)}>
              In {candidate.icmName}
            </DropdownMenu.Item>
          {/each}
        </DropdownMenu.Content>
      </DropdownMenu.Root>
      {#if preparing}
        <p class="text-ink-meta text-[12.5px]">Preparing… watch Today/Queue.</p>
      {/if}
      {#if runError}
        <p class="text-warn-ink text-[12.5px]" role="alert">{runError}</p>
      {/if}
    {/if}
  </div>
</article>
