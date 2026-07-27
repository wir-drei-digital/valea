<script lang="ts">
  // The send confirm modal (mail SMTP-send design spec G §UI) — the last
  // thing a human sees before the ONE action in this app that transmits and
  // cannot be undone.
  //
  // It renders EXCLUSIVELY from the review snapshot it was handed: one
  // backend-side no-follow read produced the recipients, subject, sending
  // identity, threading — and BOTH tokens confirming binds
  // (`contentHash`, `reviewFingerprint`). Nothing shown here may come from a
  // different read than the hashes it confirms, so this component never
  // fetches the draft, never re-hashes anything, and never reads the drafts
  // list's own (display-only) parse.
  //
  // Confirm is ONE click — no typed confirmation. The review IS the
  // confirmation, and the two tokens bind it: a draft edited in this window
  // comes back `content_changed`, an SMTP-settings or threading change comes
  // back `re_review_required`, and both are refusals BEFORE any claim, spool
  // write, or transmission. Either way the answer is the same one click:
  // Reload review.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { mailStore, type MailDraftReview } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { sendConfirmSummary, sendErrorMessage } from './mail-shapes';

  let {
    review,
    account,
    draftName,
    onclose
  }: {
    review: MailDraftReview;
    account: string;
    draftName: string;
    onclose: () => void;
  } = $props();

  // The review this modal is CURRENTLY bound to: the prop, unless "Reload
  // review" has replaced it. It is kept as ONE value rather than spread
  // across fields, because the tokens sent must always be the pair belonging
  // to the summary on screen — fields that could drift apart would break
  // exactly the guarantee this modal exists to provide.
  let reloaded: MailDraftReview | null = $state(null);
  const current = $derived(reloaded ?? review);
  let sending = $state(false);
  let reloading = $state(false);
  let error: string | null = $state(null);
  /** Set when the error is a drift refusal — the only case where reloading the review is the fix. */
  let reloadable = $state(false);

  const summary = $derived(sendConfirmSummary(current));
  const busy = $derived(sending || reloading);

  async function confirm(): Promise<void> {
    sending = true;
    error = null;
    reloadable = false;
    const outcome = await mailStore.sendDraft(
      account,
      draftName,
      current.contentHash,
      current.reviewFingerprint,
      workspaceStore.generation ?? 0
    );
    sending = false;

    if ('error' in outcome) {
      error = sendErrorMessage(outcome.error);
      reloadable = outcome.error === 're_review_required' || outcome.error === 'content_changed';
      return;
    }
    onclose();
  }

  // Both drift refusals are pre-transmit: nothing was sent, and a fresh
  // snapshot is all that stands between here and another confirm.
  async function reload(): Promise<void> {
    reloading = true;
    const next = await mailStore.draftReview(account, draftName);
    reloading = false;

    if ('error' in next) {
      error = sendErrorMessage(next.error);
      reloadable = false;
      return;
    }
    reloaded = next;
    error = null;
    reloadable = false;
  }
</script>

<Dialog.Root open={true} onOpenChange={(open: boolean) => !open && onclose()}>
  <Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-lg">
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">Send this message?</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        This sends the message over SMTP. It cannot be undone.
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-3">
      <ul class="bg-paper-pill flex flex-col gap-1 rounded-lg px-3 py-2.5">
        {#each summary as line (line)}
          <li class="text-ink-body text-[12.5px]">{line}</li>
        {/each}
      </ul>

      <div class="flex flex-col gap-1">
        <p class="text-overline">Message</p>
        <pre
          class="border-paper-hairline bg-paper-surface text-ink-body max-h-[220px] overflow-auto rounded-lg border px-3 py-2 font-mono text-[11.5px] whitespace-pre-wrap">{current.content}</pre>
      </div>

      {#if error}
        <p role="alert" class="text-warn-ink text-[12.5px]">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={() => onclose()}>Cancel</Button>
      <!-- A drift refusal REPLACES the confirm button rather than sitting
           beside it: the same tokens would be refused identically, so the
           only honest next action is a fresh review — after which Send comes
           straight back. -->
      {#if reloadable}
        <Button type="button" variant="outline" size="sm" disabled={busy} onclick={() => void reload()}>
          {reloading ? 'Reloading…' : 'Reload review'}
        </Button>
      {:else}
        <Button type="button" size="sm" disabled={busy} onclick={() => void confirm()}>
          {sending ? 'Sending…' : 'Send now'}
        </Button>
      {/if}
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
