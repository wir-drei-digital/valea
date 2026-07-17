<script lang="ts">
  // Drafts panel (mail design spec E §Drafting & push): every account's
  // agent-proposed draft files with their LEDGER-derived states, and the
  // ONE outbound affordance in the whole app — Push to Drafts, which
  // APPENDs the rendered MIME to the account's Drafts folder over IMAP.
  // THERE IS NO SMTP: nothing here (or anywhere) sends mail.
  //
  // Push binds to the exact revision the user is looking at: the store
  // fetches the draft's raw bytes, hashes them (sha256 hex — the backend's
  // own content_hash encoding), and the backend rejects the push if the
  // file changed in between (CAS).
  import { onMount } from 'svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { mailStore } from '$lib/stores/mail.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { draftStatusBadge, draftRecipientsLine, pushErrorMessage } from './mail-shapes';

  const BADGE_TONE_CLASS: Record<string, string> = {
    neutral: 'bg-paper-pill text-ink-secondary',
    busy: 'bg-paper-track text-suggest-ink',
    ok: 'bg-paper-pill text-act',
    warn: 'bg-paper-pill text-warn-ink'
  };

  let pushingName: string | null = $state(null);
  let pushError: string | null = $state(null);
  let pushErrorFor: string | null = $state(null);

  onMount(() => {
    void mailStore.refreshDrafts();
  });

  const showAccount = $derived(new Set(mailStore.drafts.map((d) => d.account)).size > 1);

  async function push(account: string, name: string): Promise<void> {
    pushingName = name;
    pushError = null;
    pushErrorFor = null;
    const outcome = await mailStore.pushDraft(account, name, workspaceStore.generation ?? 0);
    pushingName = null;
    if ('error' in outcome) {
      pushError = pushErrorMessage(outcome.error);
      pushErrorFor = name;
    }
  }
</script>

<div class="flex flex-col items-start gap-4 py-10">
  <div class="flex flex-col gap-1.5">
    <p class="text-overline">Mail</p>
    <h1 class="font-display text-ink-heading text-[21px]">Drafts</h1>
    <p class="text-ink-body max-w-[520px] text-[13.5px]">
      Files your agent proposed under each account's drafts/ folder. Nothing is ever sent — pushing places a
      draft into your mailbox's Drafts folder, where you review and send it from your own mail client.
    </p>
  </div>

  {#if mailStore.drafts.length === 0}
    <p class="text-ink-meta text-[13px]">No drafts yet.</p>
  {:else}
    <ul class="flex w-full max-w-2xl flex-col gap-2.5">
      {#each mailStore.drafts as draft (draft.account + '/' + draft.name)}
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
            <span class="min-w-2 flex-1" aria-hidden="true"></span>
            {#if draft.statusDisplay === 'draft' || draft.statusDisplay === 'rejected'}
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={pushingName !== null || 'invalid' in draft.recipients}
                onclick={() => void push(draft.account, draft.name)}
              >
                {pushingName === draft.name ? 'Pushing…' : 'Push to Drafts'}
              </Button>
            {/if}
          </div>
          <p class="text-ink-body mt-1 truncate text-[12.5px]">{draftRecipientsLine(draft.recipients)}</p>
          <p class="text-ink-meta mt-0.5 truncate font-mono text-[11px]">{draft.path}</p>
          {#if draft.notice}
            <p class="text-suggest-ink mt-1 text-[12px]">{draft.notice}</p>
          {/if}
          {#if pushError && pushErrorFor === draft.name}
            <p class="text-warn-ink mt-1 text-[12.5px]" role="alert">{pushError}</p>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}
</div>
