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
  // whole queue/workflow subsystem. The strip currently renders only the
  // "Processed" badge for an already-processed message and is otherwise
  // empty — a later task (Task 11) fills it back in with whatever replaces
  // triage.
  import Paperclip from '@lucide/svelte/icons/paperclip';
  import {
    addressEmail,
    addressListLabel,
    addressName,
    attachmentsFromFrontmatter,
    formatBytes,
    formatDateTime,
    subjectLabel,
    type RawAddress
  } from './mail-shapes';
  import type { MailMessageDetail } from '$lib/stores/mail.svelte';

  let { message }: { message: MailMessageDetail } = $props();

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

  let copiedPath: string | null = $state(null);

  // A different message was opened — drop this session's local "just
  // copied a path" affordance so it never bleeds into the newly-selected
  // message's view.
  $effect(() => {
    void message.path;
    copiedPath = null;
  });

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
      <span class="text-ink-meta text-[11px] tracking-[0.08em] uppercase">Processed</span>
    {/if}
  </div>
</article>
