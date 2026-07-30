<script lang="ts">
  // The one-time ".valea/ → .gitignore" offer under a git-backed ICM's
  // sidebar row (git-sync spec §Implementation amendments 6). Same quiet
  // shape as `SkillsOfferCard.svelte` — hairline border, no accent fill, an
  // amber "Suggested" overline — because it is the same kind of thing: a
  // suggestion, never a demand.
  //
  // It exists because Valea materializes `.valea/` (its own briefing and task
  // archive) into every ICM root, which leaves a git ICM permanently reading
  // "uncommitted changes". Valea will not edit a user's `.gitignore` on its
  // own, so this card is the consent step, and "Not now" is durable.
  import { Button } from '$lib/components/ui/button/index.js';
  import { gitStore, type GitRepoStatus } from '$lib/stores/git.svelte';
  import { VALEA_GITIGNORE_OFFER } from './icm-projects';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let { repo }: { repo: GitRepoStatus } = $props();

  let busy = $state(false);
  // Optimistic: the row that decides this card's visibility only catches up
  // on the next engine pass, and a card that lingers after its own button
  // succeeded reads as a failure.
  let taken = $state(false);
  let error = $state<string | null>(null);

  // Both actions live on `gitStore` (which also re-reads the rows after the
  // write, so the offer retires without waiting for the next engine pass);
  // this component owns only what is visual about them.
  async function addToGitignore(): Promise<void> {
    if (busy) return;
    busy = true;
    error = null;
    error = await gitStore.addValeaGitignore(repo.mountKey, workspaceStore.generation ?? 0);
    busy = false;
    if (error === null) taken = true;
  }

  async function notNow(): Promise<void> {
    if (busy) return;
    busy = true;
    error = null;
    error = await gitStore.dismissGitOffer(
      repo.mountKey,
      VALEA_GITIGNORE_OFFER,
      workspaceStore.generation ?? 0
    );
    busy = false;
    // Durable backend-side too — the `{:mounts_changed}` broadcast refetches
    // the mounts store, which is what keeps it dismissed after a reload.
    if (error === null) taken = true;
  }
</script>

{#if !taken}
  <div class="border-paper-hairline ml-[17px] mt-1 flex flex-col gap-1.5 rounded-lg border p-2.5">
    <span class="text-suggest-ink text-[11px] font-bold tracking-[0.09em] uppercase">Suggested</span>
    <p class="text-ink-body text-[12px]">
      Keep Valea's .valea/ folder out of git? It's Valea's own working data — ignoring it stops the
      permanent "uncommitted changes" state.
    </p>
    {#if repo.valeaTracked}
      <p class="text-ink-meta text-[11.5px]">
        It's already committed — this also untracks it (in Pull mode, commit the staged removal when
        ready).
      </p>
    {/if}
    <div class="flex gap-2">
      <Button type="button" size="sm" disabled={busy} onclick={() => void addToGitignore()}>
        Add to .gitignore
      </Button>
      <Button type="button" size="sm" variant="ghost" disabled={busy} onclick={() => void notNow()}>
        Not now
      </Button>
    </div>
    {#if error}
      <p class="text-warn-ink text-[11.5px]" role="alert">{error}</p>
    {/if}
  </div>
{/if}
