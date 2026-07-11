<script lang="ts">
  // Read pane for a selected message (docs/DESIGN_SYSTEM.md §8/§10): header
  // block (From/To/Subject/Date) as structured facts (label `text-ink-meta`,
  // value 600 ink — same convention as `queue/DraftReview.svelte`'s To/
  // Subject rows), body as plain preformatted TEXT (`white-space: pre-wrap`,
  // NOT markdown-rendered, NEVER `{@html}` — untrusted mail content, same
  // inert-interpolation posture as `DraftReview`'s body), attachment chips,
  // then either the "Run triage" action or a neutral "Processed" badge.
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
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import {
    addressLabel,
    addressListLabel,
    attachmentsFromFrontmatter,
    canRunTriage,
    formatBytes,
    formatDateTime,
    subjectLabel,
    type RawAddress
  } from './mail-shapes';
  import type { MailMessageDetail } from '$lib/stores/mail.svelte';

  const TRIAGE_WORKFLOW = 'icm/Workflows/New Inquiry Triage.md';

  let { message }: { message: MailMessageDetail } = $props();

  const frontmatter = $derived((message.frontmatter ?? {}) as Record<string, unknown>);
  const status = $derived(typeof frontmatter.status === 'string' ? frontmatter.status : null);
  const subject = $derived(subjectLabel(typeof frontmatter.subject === 'string' ? frontmatter.subject : null));
  const from = $derived(addressLabel(frontmatter.from as RawAddress));
  const to = $derived(addressListLabel(frontmatter.to));
  const date = $derived(typeof frontmatter.date === 'string' ? frontmatter.date : null);
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

  async function runTriage(): Promise<void> {
    running = true;
    runError = null;
    const result = await api.runWorkflow(TRIAGE_WORKFLOW, message.path, workspaceStore.generation ?? 0);
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

<div class="flex flex-col gap-6">
  <dl class="border-paper-hairline divide-paper-hairline flex flex-col divide-y rounded-lg border">
    <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
      <dt class="text-ink-meta shrink-0">From</dt>
      <dd class="text-ink-heading truncate text-right font-semibold">{from}</dd>
    </div>
    {#if to}
      <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
        <dt class="text-ink-meta shrink-0">To</dt>
        <dd class="text-ink-heading truncate text-right font-semibold">{to}</dd>
      </div>
    {/if}
    <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
      <dt class="text-ink-meta shrink-0">Subject</dt>
      <dd class="text-ink-heading truncate text-right font-semibold">{subject}</dd>
    </div>
    <div class="flex items-baseline justify-between gap-4 px-3 py-2 text-[13px]">
      <dt class="text-ink-meta shrink-0">Date</dt>
      <dd class="text-ink-heading truncate text-right font-semibold">{formatDateTime(date) || '—'}</dd>
    </div>
  </dl>

  <div class="border-paper-border bg-paper-card rounded-xl border px-5 py-4">
    <p class="text-ink-body font-sans text-[13.5px] leading-relaxed whitespace-pre-wrap">{message.body}</p>
  </div>

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

  {#if status === 'processed'}
    <span
      class="bg-paper-track text-ink-secondary inline-flex w-fit items-center rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
    >
      Processed
    </span>
  {:else}
    <div class="flex flex-wrap items-center gap-2 pt-1">
      <Button type="button" disabled={!canRun} onclick={() => void runTriage()}>Run triage</Button>
      {#if preparing}
        <p class="text-ink-meta text-[12.5px]">Preparing… watch Today/Queue.</p>
      {/if}
      {#if runError}
        <p class="text-warn-ink text-[12.5px]" role="alert">{runError}</p>
      {/if}
    </div>
  {/if}
</div>
