<script lang="ts">
  // Drafts panel (mail design spec E §Drafting & push + spec G §UI): every
  // account's agent-proposed draft files with their LEDGER-derived states,
  // and the two outbound affordances in the whole app — Push to Drafts
  // (APPENDs the rendered MIME to the mailbox's Drafts folder) and Send
  // (SMTP, human-only, behind the confirm modal).
  //
  // Both bind to the exact revision the user is looking at, by different
  // routes: Push fetches-and-hashes here, Send takes its hash (and the
  // review fingerprint covering the sending identity and threading) from the
  // review snapshot the modal renders. Agents can neither push nor send —
  // this surface is control-token-gated and reachable only from the app.
  //
  // The third affordance is inbound, not outbound: "Request changes" hands
  // feedback back to an agent, which edits the draft file in place. It routes
  // server-side to the session already working on this draft when there is
  // one, and starts one otherwise — see `api.reviseMailDraft`.
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { mostRecentMountKey } from '$lib/today/quick-session';
  import { mailStore, type MailDraft, type MailDraftReview } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import {
    draftStatusBadge,
    draftRecipientsLine,
    pushErrorMessage,
    canSendDraft,
    canReviseDraft,
    draftNoticeMessage,
    sendErrorMessage,
    sendReviewExplanation,
    reviseOutcomeMessage,
    reviseErrorMessage,
    NO_HOST_ICM_MESSAGE
  } from './mail-shapes';
  import { composeHref } from './compose';
  import SendConfirmModal from './SendConfirmModal.svelte';

  const BADGE_TONE_CLASS: Record<string, string> = {
    neutral: 'bg-paper-pill text-ink-secondary',
    busy: 'bg-paper-track text-suggest-ink',
    ok: 'bg-paper-pill text-act',
    warn: 'bg-paper-pill text-warn-ink'
  };

  // Keyed by `account + '/' + name`, never name alone: two accounts can each
  // hold a same-named draft (`reply.md`), and keying by name would cross-talk —
  // the "Pushing…" label and the error would appear on BOTH rows.
  let pushingKey: string | null = $state(null);
  let pushError: string | null = $state(null);
  let pushErrorKey: string | null = $state(null);

  // The send flow's own row-scoped state: which row is fetching its review,
  // which row's resolution/retry is in flight, and the row-scoped error.
  let reviewingKey: string | null = $state(null);
  let resolvingKey: string | null = $state(null);
  let sendError: string | null = $state(null);
  let sendErrorKey: string | null = $state(null);
  // The typed verdict awaiting its second click. `send_review` resolutions
  // are irreversible in opposite ways (one appends a Sent copy and closes the
  // op, the other re-arms an unsent message for another explicit send), so
  // each names its consequence before it runs.
  let pendingVerdict: { key: string; resolution: 'sent' | 'not_sent' } | null = $state(null);
  // The open confirm modal's review snapshot, held with the row it belongs to.
  let openReview: { account: string; draftName: string; review: MailDraftReview } | null = $state(null);

  // "Request changes": which row's feedback form is open, what is typed in it,
  // which row's submit is in flight, and the row-scoped error / success. The
  // success carries the session id so the confirmation can link to it.
  let revisingKey: string | null = $state(null);
  let feedback = $state('');
  let submittingKey: string | null = $state(null);
  let reviseError: string | null = $state(null);
  let reviseErrorKey: string | null = $state(null);
  let revised: { key: string; sessionId: string; message: string } | null = $state(null);

  const draftKey = (account: string, name: string): string => `${account}/${name}`;

  onMount(() => {
    void mailStore.refreshDrafts();
  });

  const showAccount = $derived(new Set(mailStore.drafts.map((d) => d.account)).size > 1);
  const generation = $derived(workspaceStore.generation ?? 0);
  const busy = $derived(
    pushingKey !== null || reviewingKey !== null || resolvingKey !== null || submittingKey !== null
  );

  // Which ICM hosts a session started from here: the one most recently worked
  // in, falling back to the first enabled mount — the same target Today's
  // quick composer picks, so "my assistant" means the same project everywhere.
  // `null` when no mount can host one at all.
  const hostMountKey = $derived(mostRecentMountKey(recentSessionsStore.groups, icmStore.groups[0]?.mount ?? null));

  function accountStatus(slug: string) {
    return mailStore.accounts.find((a) => a.account === slug) ?? null;
  }

  function clearErrors(): void {
    pushError = null;
    pushErrorKey = null;
    sendError = null;
    sendErrorKey = null;
    reviseError = null;
    reviseErrorKey = null;
  }

  // Opening the form on a row closes it everywhere else — one draft at a
  // time, and the typed text never follows the user to a different draft.
  function toggleRevise(key: string): void {
    clearErrors();
    revised = null;
    feedback = '';
    revisingKey = revisingKey === key ? null : key;
  }

  async function requestChanges(draft: MailDraft): Promise<void> {
    const key = draftKey(draft.account, draft.name);
    const text = feedback.trim();
    if (!text) return;

    clearErrors();
    revised = null;

    if (!hostMountKey) {
      reviseError = NO_HOST_ICM_MESSAGE;
      reviseErrorKey = key;
      return;
    }

    submittingKey = key;
    const result = await api.reviseMailDraft(draft.account, draft.name, text, hostMountKey, generation);
    submittingKey = null;

    if (!result.ok) {
      reviseError = reviseErrorMessage(result.error);
      reviseErrorKey = key;
      return;
    }

    const data = result.data as { sessionId: string; routed: string };
    revised = { key, sessionId: data.sessionId, message: reviseOutcomeMessage(data.routed) };
    revisingKey = null;
    feedback = '';
    // A new session belongs in the sidebar's recent list right away — the
    // same refresh `/chat` and Today do after starting one.
    void recentSessionsStore.refresh();
  }

  async function push(account: string, name: string): Promise<void> {
    const key = draftKey(account, name);
    pushingKey = key;
    clearErrors();
    const outcome = await mailStore.pushDraft(account, name, generation);
    pushingKey = null;
    if ('error' in outcome) {
      pushError = pushErrorMessage(outcome.error);
      pushErrorKey = key;
    }
  }

  // Send is TWO steps, and this is the first: fetch the atomic review
  // snapshot and hand it to the modal, which owns the confirmation and the
  // transmit. Nothing here is sent, claimed, or written.
  async function openSend(account: string, name: string): Promise<void> {
    const key = draftKey(account, name);
    reviewingKey = key;
    clearErrors();
    const review = await mailStore.draftReview(account, name);
    reviewingKey = null;

    if ('error' in review) {
      sendError = sendErrorMessage(review.error);
      sendErrorKey = key;
      return;
    }
    openReview = { account, draftName: name, review };
  }

  async function resolve(draft: MailDraft): Promise<void> {
    const key = draftKey(draft.account, draft.name);
    const verdict = pendingVerdict;
    if (!draft.opId || verdict?.key !== key) return;

    resolvingKey = key;
    clearErrors();
    pendingVerdict = null;
    const error = await mailStore.resolveSendReview(draft.account, draft.opId, verdict.resolution, generation);
    resolvingKey = null;
    if (error) {
      sendError = sendErrorMessage(error);
      sendErrorKey = key;
    }
  }

  async function retryCopy(draft: MailDraft): Promise<void> {
    if (!draft.opId) return;
    const key = draftKey(draft.account, draft.name);
    resolvingKey = key;
    clearErrors();
    const error = await mailStore.retrySentCopy(draft.account, draft.opId, generation);
    resolvingKey = null;
    if (error) {
      sendError = sendErrorMessage(error);
      sendErrorKey = key;
    }
  }
</script>

<div class="flex flex-col items-start gap-4 py-10">
  <div class="flex flex-col gap-1.5">
    <h1 class="font-display text-ink-heading text-[21px]">Drafts</h1>
    <p class="text-ink-body max-w-[520px] text-[13.5px]">
      Files your agent proposed under each account's drafts/ folder. Your agent can never send one — pushing places a
      draft into your mailbox's Drafts folder, and sending happens only when you confirm it here.
    </p>
  </div>

  {#if mailStore.drafts.length === 0}
    <p class="text-ink-meta text-[13px]">No drafts yet.</p>
  {:else}
    <ul class="flex w-full max-w-2xl flex-col gap-2.5">
      {#each mailStore.drafts as draft (draft.account + '/' + draft.name)}
        {@const key = draftKey(draft.account, draft.name)}
        {@const badge = draftStatusBadge(draft.statusDisplay)}
        <li class="border-paper-border bg-paper-card rounded-xl border px-4 py-3">
          <div class="flex items-center gap-2.5">
            <span class="text-ink-heading min-w-0 truncate text-[13.5px] font-medium">{draft.name}</span>
            {#if showAccount}
              <span class="text-ink-meta shrink-0 text-[11.5px]">{draft.account}</span>
            {/if}
            <span
              class="inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-[11px] font-semibold {BADGE_TONE_CLASS[
                badge.tone
              ]}"
            >
              {badge.label}
            </span>
            <!-- `pushed` is a FACT beside the state, never the state itself:
                 a pushed-then-edited draft still reads "Draft" and still
                 offers both actions. -->
            {#if draft.pushed && draft.statusDisplay !== 'pushed'}
              <span
                class="border-paper-hairline text-ink-meta inline-flex shrink-0 items-center rounded-full border px-2 py-0.5 text-[11px]"
              >
                Pushed
              </span>
            {/if}
            <span class="min-w-2 flex-1" aria-hidden="true"></span>
            {#if canSendDraft(draft, accountStatus(draft.account))}
              <Button type="button" size="sm" disabled={busy} onclick={() => void openSend(draft.account, draft.name)}>
                {reviewingKey === key ? 'Opening…' : 'Send'}
              </Button>
            {/if}
            {#if draft.statusDisplay === 'draft' || draft.statusDisplay === 'rejected'}
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={busy || 'invalid' in draft.recipients}
                onclick={() => void push(draft.account, draft.name)}
              >
                {pushingKey === key ? 'Pushing…' : 'Push to Drafts'}
              </Button>
            {/if}
            <!-- Edit it yourself, in the composer. Offered on exactly the
                 state `write_mail_draft` accepts — anything else would open an
                 editor whose Save is guaranteed to come back `draft_busy`. -->
            {#if draft.statusDisplay === 'draft'}
              <Button
                type="button"
                variant="ghost"
                size="sm"
                disabled={busy}
                onclick={() => void goto(composeHref(draft.account, draft.name))}
              >
                Edit
              </Button>
            {/if}
            {#if canReviseDraft(draft)}
              <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={() => toggleRevise(key)}>
                Request changes
              </Button>
            {/if}
          </div>
          <p class="text-ink-body mt-1 truncate text-[12.5px]">{draftRecipientsLine(draft.recipients)}</p>
          <p class="text-ink-meta mt-0.5 truncate font-mono text-[11px]">{draft.path}</p>

          {#if draft.statusDisplay === 'send_review'}
            <!-- A parked send: the outcome is genuinely unknown and only the
                 human can settle it. The explanation states what was (or
                 could not be) checked before asking. -->
            <p class="text-warn-ink mt-1.5 text-[12.5px]">{sendReviewExplanation(draft.notice)}</p>
            {#if draft.opId}
              {#if pendingVerdict?.key === key}
                <div class="bg-paper-pill mt-2 flex flex-col gap-2 rounded-lg px-3 py-2.5">
                  <p class="text-ink-body text-[12.5px]">
                    {pendingVerdict.resolution === 'sent'
                      ? 'Marking it sent files a copy in your Sent folder and closes this out. Nothing is transmitted.'
                      : 'Marking it not sent puts the file back to a draft you can send again — if it did go out, the recipient gets a second copy.'}
                  </p>
                  <div class="flex items-center gap-2">
                    <Button type="button" size="sm" disabled={busy} onclick={() => void resolve(draft)}>
                      {resolvingKey === key ? 'Saving…' : 'Confirm'}
                    </Button>
                    <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={() => (pendingVerdict = null)}>
                      Cancel
                    </Button>
                  </div>
                </div>
              {:else}
                <div class="mt-2 flex items-center gap-2">
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={busy}
                    onclick={() => (pendingVerdict = { key, resolution: 'sent' })}
                  >
                    It was sent…
                  </Button>
                  <Button
                    type="button"
                    variant="outline"
                    size="sm"
                    disabled={busy}
                    onclick={() => (pendingVerdict = { key, resolution: 'not_sent' })}
                  >
                    It was not sent…
                  </Button>
                </div>
              {/if}
            {/if}
          {:else if draft.statusDisplay === 'sent' && draft.notice === 'sent_copy_failed'}
            <!-- The mail IS transmitted; only its Sent-folder copy is
                 outstanding. The retry re-runs that idempotent append alone —
                 it cannot reach the SMTP transport. -->
            <p class="text-suggest-ink mt-1.5 text-[12.5px]">
              This was sent, but the copy for your Sent folder didn't land. Retrying files the copy — it never re-sends
              the message.
            </p>
            {#if draft.opId}
              <div class="mt-2">
                <Button type="button" variant="outline" size="sm" disabled={busy} onclick={() => void retryCopy(draft)}>
                  {resolvingKey === key ? 'Retrying…' : 'Retry Sent copy'}
                </Button>
              </div>
            {/if}
          {:else if draft.notice}
            <p class="text-suggest-ink mt-1 text-[12px]">{draftNoticeMessage(draft.notice)}</p>
          {/if}

          {#if revisingKey === key}
            <!-- Feedback goes to an agent, which edits this file in place —
                 it is never a message to anyone, and cannot send. -->
            <div class="bg-paper-pill mt-2 flex flex-col gap-2 rounded-lg px-3 py-2.5">
              <label class="text-ink-body text-[12.5px]" for="revise-{key}">What should change?</label>
              <textarea
                id="revise-{key}"
                class="border-paper-hairline bg-paper-surface min-h-16 rounded-[7px] border px-2 py-1.5 text-[12.5px]"
                placeholder="Warmer opening, and mention we can meet Tuesday."
                bind:value={feedback}
              ></textarea>
              <div class="flex items-center gap-2">
                <Button type="button" size="sm" disabled={busy || feedback.trim() === ''} onclick={() => void requestChanges(draft)}>
                  {submittingKey === key ? 'Sending…' : 'Send to assistant'}
                </Button>
                <Button type="button" variant="ghost" size="sm" disabled={busy} onclick={() => toggleRevise(key)}>
                  Cancel
                </Button>
              </div>
            </div>
          {/if}
          {#if revised?.key === key}
            <p class="text-ink-body mt-1.5 text-[12.5px]">
              {revised.message}
              <button
                type="button"
                class="text-act underline underline-offset-2"
                onclick={() => void goto(`/chat?session=${revised?.sessionId}`)}
              >
                Open it
              </button>
            </p>
          {/if}

          {#if pushError && pushErrorKey === key}
            <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{pushError}</p>
          {/if}
          {#if sendError && sendErrorKey === key}
            <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{sendError}</p>
          {/if}
          {#if reviseError && reviseErrorKey === key}
            <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{reviseError}</p>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>

{#if openReview}
  <SendConfirmModal
    review={openReview.review}
    account={openReview.account}
    draftName={openReview.draftName}
    onclose={() => (openReview = null)}
  />
{/if}
