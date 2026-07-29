<script lang="ts">
  // The composer (mail full-client design §M2 §Compose UI) — the human's own
  // pen for a draft file, behind `?compose=new` / `?compose=<draftName>` in
  // the mail route's main pane.
  //
  // Deliberately thin: every rule about draft bytes lives in `compose.ts`
  // (rendering the frontmatter, reading it back, recipient math, quoting) and
  // every RPC in `mailStore`, because a component is the one thing this
  // codebase cannot unit-test. What is left here is state wiring and markup.
  //
  // Plain text only, by design (spec §M2: "compose is plain-text"). There is
  // no rich-text mode and no `{@html}` anywhere near mail content.
  //
  // Three things the editor refuses to do, all for the same reason — never
  // write bytes over something it did not read:
  //
  //   * a draft whose LEDGER state is not `draft` (pushing/sending/sent/…)
  //     opens read-only with that state named. `write_mail_draft` would
  //     answer `draft_busy`, and a `sent` one is locked permanently;
  //   * frontmatter `parseDraftFields` will not claim to understand opens
  //     read-only as raw text — the composer rewrites the whole file on save,
  //     so a field it misread would be a field it silently dropped;
  //   * every save carries the hash of the revision it started from, so an
  //     edit made against bytes an agent has since replaced comes back
  //     `content_changed` instead of clobbering them.
  import { beforeNavigate, goto } from '$app/navigation';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { api } from '$lib/api/client';
  import { mailStore, type MailDraftReview } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import {
    canSendDraft,
    draftStatusBadge,
    pushErrorMessage,
    sendErrorMessage,
    sha256Hex
  } from './mail-shapes';
  import {
    composeHref,
    composeValidationError,
    draftContent,
    emptyDraftFields,
    formatAddressList,
    parseAddressList,
    parseDraftFields,
    saveErrorMessage,
    takeComposePrefill,
    type DraftFields
  } from './compose';
  import SendConfirmModal from './SendConfirmModal.svelte';

  let {
    account,
    draftName
  }: {
    account: string;
    /**
     * `null` for `?compose=new`; otherwise the draft file's name exactly as
     * this RPC surface spells it — `.md` included (`list_mail_drafts`,
     * `get_mail_draft` and `write_mail_draft` all take it that way).
     */
    draftName: string | null;
  } = $props();

  const BADGE_TONE_CLASS: Record<string, string> = {
    neutral: 'bg-paper-pill text-ink-secondary',
    busy: 'bg-paper-track text-suggest-ink',
    ok: 'bg-paper-pill text-act',
    warn: 'bg-paper-pill text-warn-ink'
  };

  // The form. Recipients are edited as TEXT (one field each) and parsed into
  // mailbox strings only when the draft is rendered — what the user is
  // half-way through typing is not a list yet.
  let toText = $state('');
  let ccText = $state('');
  let bccText = $state('');
  let subject = $state('');
  let body = $state('');
  /**
   * The threading hint, carried but never edited: it comes from the message
   * being replied to (a msg_id), and the real `In-Reply-To`/`References`
   * headers resolve backend-side at review time.
   */
  let inReplyTo = $state<string | null>(null);

  /** The draft's name once it exists on disk — minted by the first save of a new draft. */
  let name = $state<string | null>(null);
  /** The revision every save compares against (`null` = "this draft does not exist yet"). */
  let baseHash = $state<string | null>(null);
  /** The bytes currently on disk, as this composer last saw them — the dirty comparison. */
  let savedContent = $state<string | null>(null);

  let phase = $state<'loading' | 'ready' | 'error'>('loading');
  let loadError = $state<string | null>(null);
  /** Set when the draft's frontmatter is not editable here — its raw bytes, shown read-only. */
  let unsupportedRaw = $state<string | null>(null);

  let saving = $state(false);
  let reviewing = $state(false);
  let pushing = $state(false);
  let actionError = $state<string | null>(null);
  /** Whether `actionError` is one a re-read of the file could resolve (a refusal, not a typo in the form). */
  let errorReloadable = $state(false);
  let notice = $state<string | null>(null);
  /** A different writer landed bytes between our write and the read-back. */
  let raced = $state(false);

  let openReview = $state<MailDraftReview | null>(null);

  // Unsaved-changes guard: `beforeNavigate` cancels synchronously (the only
  // way to stop a SvelteKit navigation) and the dialog then decides.
  let pendingNav = $state<URL | null>(null);
  let leaving = false;

  const generation = $derived(workspaceStore.generation ?? 0);

  const fields = $derived<DraftFields>({
    to: parseAddressList(toText),
    cc: parseAddressList(ccText),
    bcc: parseAddressList(bccText),
    subject,
    inReplyTo,
    body
  });
  const content = $derived(draftContent(fields));

  /** The draft's row in the workspace-wide list — where its LEDGER-derived state lives. */
  const row = $derived(
    name === null ? null : (mailStore.drafts.find((d) => d.account === account && d.name === name) ?? null)
  );
  /** Non-`draft` state → the editor is read-only, labelled with the Drafts panel's own vocabulary. */
  const lockedBadge = $derived(
    row !== null && row.statusDisplay !== 'draft' ? draftStatusBadge(row.statusDisplay) : null
  );
  const readOnly = $derived(lockedBadge !== null || unsupportedRaw !== null);

  const accountStatus = $derived(mailStore.accounts.find((a) => a.account === account) ?? null);
  /**
   * Whether this composer offers "Review & send…" or only "Push to Drafts" —
   * `canSendDraft`, the Drafts panel's own gate, so the two can never drift.
   * The row it is asked about is the one this composer is about to write:
   * `write_mail_draft` accepts nothing but a parseable draft in state
   * `draft`, so the only open question left for the gate is the account's.
   */
  const sendable = $derived(
    canSendDraft(
      { statusDisplay: 'draft', recipients: { to: [], cc: [], bcc: [], subject: null } },
      accountStatus
    )
  );

  const busy = $derived(saving || reviewing || pushing);
  const dirty = $derived(
    !readOnly &&
      (savedContent === null
        ? toText.trim() !== '' || ccText.trim() !== '' || bccText.trim() !== '' || subject.trim() !== '' || body.trim() !== ''
        : content !== savedContent)
  );

  function applyFields(next: DraftFields): void {
    toText = formatAddressList(next.to);
    ccText = formatAddressList(next.cc);
    bccText = formatAddressList(next.bcc);
    subject = next.subject;
    body = next.body;
    inReplyTo = next.inReplyTo;
  }

  function resetForm(): void {
    applyFields(emptyDraftFields());
    baseHash = null;
    savedContent = null;
    unsupportedRaw = null;
    loadError = null;
    actionError = null;
    errorReloadable = false;
    notice = null;
    raced = false;
    phase = 'loading';
  }

  /**
   * Reads one draft off disk into the form. A sequence number, not a
   * cancellation flag, guards the awaits: switching drafts (or reloading)
   * mid-fetch must drop the slower response rather than let it overwrite the
   * newer form.
   */
  let loadSeq = 0;

  async function loadDraft(acct: string, target: string, seq: number): Promise<void> {
    const result = await api.getMailDraft(acct, target);
    if (seq !== loadSeq) return;
    if (!result.ok) {
      loadError = saveErrorMessage(result.error);
      phase = 'error';
      return;
    }

    const bytes = (result.data as { content: string }).content;
    const hash = await sha256Hex(bytes);
    if (seq !== loadSeq) return;

    const parsed = parseDraftFields(bytes);
    if (parsed.ok) applyFields(parsed.fields);
    else unsupportedRaw = bytes;

    name = target;
    baseHash = hash;
    savedContent = bytes;
    phase = 'ready';
    // The row carries the ledger state this editor gates on.
    void mailStore.refreshDrafts();
  }

  $effect(() => {
    const acct = account;
    const target = draftName;
    const seq = ++loadSeq;

    resetForm();
    name = target;

    if (target === null) {
      // A prefill stashed by the read pane's Reply/Reply-all/Forward, taken
      // exactly once — a reload of `?compose=new` is simply an empty composer.
      const prefill = takeComposePrefill(acct);
      if (prefill) applyFields(prefill);
      phase = 'ready';
      return;
    }

    void loadDraft(acct, target, seq);
  });

  /** Writes the draft; resolves its name, or `null` when nothing was written. */
  async function save(): Promise<string | null> {
    if (readOnly || busy) return null;

    const invalid = composeValidationError(fields);
    if (invalid) {
      actionError = invalid;
      errorReloadable = false;
      return null;
    }

    saving = true;
    actionError = null;
    errorReloadable = false;
    notice = null;
    raced = false;
    const written = content;
    const outcome = await mailStore.saveDraft(account, name, written, baseHash, generation);
    saving = false;

    if ('error' in outcome) {
      actionError = saveErrorMessage(outcome.error);
      errorReloadable = name !== null;
      return null;
    }

    name = outcome.name;
    baseHash = outcome.hash;
    savedContent = outcome.content;
    raced = outcome.content !== written;
    notice = raced ? null : `Saved as ${outcome.name}`;
    return outcome.name;
  }

  /**
   * Saves only when there is something to save — a clean, already-named draft
   * is left alone. The `readOnly` guard is belt-and-braces (the whole action
   * row is hidden then): `dirty` is false for a locked draft, so without it
   * this would hand a name straight back and let a send flow start off an
   * editor that is explicitly not in charge of those bytes.
   */
  async function ensureSaved(): Promise<string | null> {
    if (readOnly) return null;
    if (name !== null && !dirty) return name;
    return save();
  }

  async function reviewAndSend(): Promise<void> {
    const saved = await ensureSaved();
    if (!saved) return;

    reviewing = true;
    const review = await mailStore.draftReview(account, saved);
    reviewing = false;

    if ('error' in review) {
      actionError = sendErrorMessage(review.error);
      errorReloadable = true;
      return;
    }
    openReview = review;
  }

  async function pushToDrafts(): Promise<void> {
    const saved = await ensureSaved();
    if (!saved) return;

    pushing = true;
    const outcome = await mailStore.pushDraft(account, saved, generation);
    pushing = false;

    if ('error' in outcome) {
      actionError = pushErrorMessage(outcome.error);
      errorReloadable = true;
    } else {
      notice = 'Pushed to your mailbox’s Drafts folder.';
    }
  }

  /**
   * Re-reads the draft from disk, discarding the buffer — the answer to a CAS
   * conflict (`content_changed`) and to a write that got raced. Deliberately
   * NOT a navigation: the composer is often already AT this draft's URL, and
   * `goto` to the URL you are on changes no prop, so nothing would reload.
   */
  function reloadFromDisk(): void {
    const target = name;
    if (target === null) return;
    const seq = ++loadSeq;
    resetForm();
    void loadDraft(account, target, seq);
  }

  // Route-leave: a composer holding unsaved text must not lose it to a stray
  // click in the list. `beforeNavigate` can only cancel synchronously, so it
  // parks the target and the dialog below decides. A full-page unload
  // (`nav.to === null`) is deliberately not fought over.
  beforeNavigate((nav) => {
    if (!dirty || leaving || !nav.to) return;
    const url = nav.to.url;
    const sameComposer =
      url.pathname === '/mail' && url.searchParams.get('compose') === (draftName ?? 'new');
    if (sameComposer) return;
    nav.cancel();
    pendingNav = url;
  });

  function discardAndLeave(): void {
    const target = pendingNav;
    pendingNav = null;
    if (!target) return;
    leaving = true;
    void goto(target.toString());
  }
</script>

<div class="flex flex-col gap-5 py-8">
  <div class="flex flex-col gap-1.5">
    <p class="text-overline">Mail</p>
    <div class="flex flex-wrap items-center gap-2.5">
      <h1 class="font-display text-ink-heading text-[21px]">
        {draftName === null ? 'New message' : 'Draft'}
      </h1>
      {#if lockedBadge}
        <span
          class="inline-flex shrink-0 items-center rounded-full px-2 py-0.5 text-[11px] font-semibold {BADGE_TONE_CLASS[
            lockedBadge.tone
          ]}"
        >
          {lockedBadge.label}
        </span>
      {/if}
    </div>
    {#if name}
      <p class="text-ink-meta truncate font-mono text-[11px]">{name}</p>
    {/if}
  </div>

  {#if phase === 'loading'}
    <p class="text-ink-meta text-[13px]">Loading…</p>
  {:else if phase === 'error'}
    <p class="text-warn-ink text-[13px]" role="alert">{loadError}</p>
  {:else}
    {#if lockedBadge}
      <p class="border-paper-border bg-paper-card text-ink-body rounded-lg border px-3.5 py-2.5 text-[12.5px]">
        This draft can't be edited here — it is “{lockedBadge.label}”. A draft that has been sent stays exactly as it
        was reviewed; one that is mid-push or mid-send becomes editable again once that finishes. The Drafts panel
        keeps whatever actions it still has.
      </p>
    {:else if unsupportedRaw !== null}
      <p class="border-paper-border bg-paper-card text-ink-body rounded-lg border px-3.5 py-2.5 text-[12.5px]">
        This draft's frontmatter isn't in a shape this editor can rewrite safely, so it is shown as written. Ask your
        assistant to change it from the Drafts panel, or edit the file directly.
      </p>
    {/if}

    {#if unsupportedRaw !== null}
      <pre
        class="border-paper-hairline bg-paper-surface text-ink-body max-h-[420px] overflow-auto rounded-lg border px-3 py-2 font-mono text-[11.5px] whitespace-pre-wrap">{unsupportedRaw}</pre>
    {:else}
      <div class="flex flex-col gap-3.5">
        <div class="flex flex-col gap-1.5">
          <Label for="compose-to">To</Label>
          <Input
            id="compose-to"
            bind:value={toText}
            disabled={readOnly || busy}
            autocomplete="off"
            placeholder="alex@example.com, Bo &lt;bo@example.com&gt;"
          />
        </div>

        <div class="flex gap-3">
          <div class="flex flex-1 flex-col gap-1.5">
            <Label for="compose-cc">Cc</Label>
            <Input id="compose-cc" bind:value={ccText} disabled={readOnly || busy} autocomplete="off" />
          </div>
          <div class="flex flex-1 flex-col gap-1.5">
            <Label for="compose-bcc">Bcc</Label>
            <Input id="compose-bcc" bind:value={bccText} disabled={readOnly || busy} autocomplete="off" />
          </div>
        </div>

        <div class="flex flex-col gap-1.5">
          <Label for="compose-subject">Subject</Label>
          <Input id="compose-subject" bind:value={subject} disabled={readOnly || busy} autocomplete="off" />
        </div>

        <div class="flex flex-col gap-1.5">
          <Label for="compose-body">Message</Label>
          <textarea
            id="compose-body"
            class="border-paper-hairline bg-paper-surface text-ink-body min-h-64 rounded-[7px] border px-3 py-2 text-[13.5px] leading-[1.6]"
            bind:value={body}
            disabled={readOnly || busy}
          ></textarea>
          <p class="text-ink-meta text-[11.5px]">
            Plain text. Your assistant can't send this — you push or send it yourself.
          </p>
        </div>

        {#if inReplyTo}
          <p class="text-ink-meta text-[11.5px]">
            Replying in the thread of <span class="font-mono">{inReplyTo}</span>
          </p>
        {/if}
      </div>
    {/if}

    {#if !readOnly}
      <div class="border-paper-hairline flex flex-col gap-2 border-t pt-4">
        <div class="flex flex-wrap items-center gap-2.5">
          <Button type="button" variant="outline" disabled={busy || !dirty} onclick={() => void save()}>
            {saving ? 'Saving…' : 'Save'}
          </Button>
          {#if sendable}
            <Button type="button" disabled={busy} onclick={() => void reviewAndSend()}>
              {reviewing ? 'Opening…' : 'Review & send…'}
            </Button>
          {:else}
            <!-- Push-only account (no `smtp:` block): the draft can be filed
                 into the mailbox's Drafts folder, and sent from wherever you
                 read your mail. -->
            <Button type="button" disabled={busy} onclick={() => void pushToDrafts()}>
              {pushing ? 'Pushing…' : 'Push to Drafts'}
            </Button>
          {/if}
          {#if dirty}
            <span class="text-ink-meta text-[11.5px]">Unsaved changes</span>
          {/if}
        </div>

        {#if raced}
          <p class="text-suggest-ink text-[12.5px]">
            Your changes were saved, but the file on disk changed again right after — your assistant may be editing it
            too.
            <button type="button" class="text-act underline underline-offset-2" onclick={() => reloadFromDisk()}>
              Reload from disk
            </button>
          </p>
        {:else if notice}
          <p class="text-ink-body text-[12.5px]">{notice}</p>
        {/if}
        {#if actionError}
          <p class="text-warn-ink text-[12.5px]" role="alert">
            {actionError}
            {#if errorReloadable && name}
              <button type="button" class="text-act underline underline-offset-2" onclick={() => reloadFromDisk()}>
                Reload from disk
              </button>
            {/if}
          </p>
        {/if}
      </div>
    {/if}
  {/if}
</div>

{#if openReview && name}
  <SendConfirmModal
    review={openReview}
    {account}
    draftName={name}
    onclose={() => (openReview = null)}
  />
{/if}

<!-- Leaving with unsaved text: the navigation is already cancelled, so this
     dialog is the only thing that can resume it. -->
<Dialog.Root open={pendingNav !== null} onOpenChange={(open: boolean) => !open && (pendingNav = null)}>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">Leave without saving?</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        This message has changes that aren't in the draft file yet. Leaving loses them.
      </Dialog.Description>
    </Dialog.Header>
    <Dialog.Footer>
      <Button type="button" variant="ghost" size="sm" onclick={() => (pendingNav = null)}>Keep editing</Button>
      <Button type="button" size="sm" onclick={() => discardAndLeave()}>Discard and leave</Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
