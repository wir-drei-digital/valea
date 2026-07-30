<script lang="ts">
  // Per-ICM git sync settings (ICM git sync spec §UI "ICM settings"): the
  // repo's live state, the one sync-mode knob, "Sync now", and the same
  // Resolve/Open handoff the Today attention rows offer.
  //
  // ONE knob on purpose, not three: `full` (fetch + ff + auto-commit +
  // auto-push), `pull` (fetch + fast-forward only) and `off`. Auto-push
  // follows auto-commit — a repo that commits for you and then sits on the
  // commits would just be a slower way to diverge.
  //
  // Reads `gitStore` rather than fetching its own status: the store is the
  // one place the `git_status` push lands, so this panel updates live while
  // it is open (a pass finishing, a conflict clearing) with no polling.
  import { goto } from '$app/navigation';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import {
    gitStore,
    gitAttentionText,
    gitStateLabel,
    resolveGitConflict,
    type GitRepoStatus
  } from '$lib/stores/git.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  // Controlled, like `IcmProjects.svelte`'s Diagnose dialog: the parent owns
  // WHICH ICM is showing, so it must own whether the panel is open too —
  // there is no state here worth binding back.
  let {
    open,
    onOpenChange,
    mountKey,
    name
  }: {
    open: boolean;
    onOpenChange: (open: boolean) => void;
    mountKey: string;
    name: string;
  } = $props();

  const repo = $derived(gitStore.byMountKey(mountKey));
  const attention = $derived(gitStore.attention(mountKey));

  const MODES: { value: string; label: string; description: string }[] = [
    { value: 'off', label: 'Off', description: 'Valea leaves this repository alone.' },
    {
      value: 'pull',
      label: 'Pull only',
      description: 'Fetch and fast-forward. Nothing is committed or pushed for you.'
    },
    {
      value: 'full',
      label: 'Full sync',
      description: 'Also commits your changes and pushes them to the remote.'
    }
  ];

  let saving = $state(false);
  let syncing = $state(false);
  let resolving = $state(false);
  let error = $state<string | null>(null);
  let syncFlash = $state(false);

  // A fresh read every time the panel opens: the rows may be a whole pass old
  // (the push only fires when the engine finishes one), and this is the
  // surface where staleness would read as the controls not working.
  $effect(() => {
    if (open) {
      error = null;
      syncFlash = false;
      void gitStore.refresh(workspaceStore.generation ?? 0);
    }
  });

  async function chooseMode(mode: string): Promise<void> {
    if (saving || repo?.mode === mode) return;
    saving = true;
    error = null;
    error = await gitStore.setMode(mountKey, mode, workspaceStore.generation ?? 0);
    saving = false;
  }

  async function syncNow(): Promise<void> {
    syncing = true;
    error = null;
    syncFlash = false;
    const failure = await gitStore.syncNow(mountKey, workspaceStore.generation ?? 0);
    syncing = false;
    if (failure) {
      error = failure;
      return;
    }
    // "Started", not "finished" — the pass runs on its own and reports back
    // through the `git_status` push, which updates this panel in place.
    syncFlash = true;
    setTimeout(() => (syncFlash = false), 2000);
  }

  async function resolve(target: GitRepoStatus): Promise<void> {
    if (resolving) return;
    resolving = true;
    error = null;
    try {
      const outcome = await resolveGitConflict(target, workspaceStore.generation ?? 0);
      if (outcome.ok) {
        onOpenChange(false);
        void goto(`/chat?session=${outcome.sessionId}`);
      } else {
        error = outcome.error;
      }
    } finally {
      resolving = false;
    }
  }

  function formatTimestamp(iso: string): string {
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return iso;
    return parsed.toLocaleString(undefined, {
      month: 'short',
      day: 'numeric',
      hour: '2-digit',
      minute: '2-digit'
    });
  }
</script>

<Dialog.Root {open} {onOpenChange}>
  <Dialog.Content class="max-h-[85vh] overflow-y-auto sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-ink-heading text-[19px]">Git sync: {name}</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        Valea keeps this project's git repository in step with its remote. It never rewrites
        history — no rebases onto shared branches, no force pushes.
      </Dialog.Description>
    </Dialog.Header>

    {#if !repo}
      <p class="text-ink-meta text-[13px]">
        No git status for this project yet. It may not be a git repository, or the workspace may
        still be starting.
      </p>
    {:else}
      <div class="border-paper-hairline flex flex-col gap-1 border-b pb-3">
        <p class="text-[13px]">
          <span class={attention || repo.state === 'error' ? 'text-warn-ink' : 'text-ink-heading'}>
            {gitStateLabel(repo.state)}
          </span>
          {#if repo.branch}
            <span class="text-ink-meta">· {repo.branch}</span>
          {/if}
          {#if repo.ahead > 0 || repo.behind > 0}
            <span class="text-ink-meta tabular-nums">
              · {repo.ahead} ahead / {repo.behind} behind
            </span>
          {/if}
          {#if repo.dirty}
            <span class="text-ink-meta">· uncommitted changes</span>
          {/if}
        </p>
        {#if repo.reason}
          <p class="text-ink-meta text-[12px]">{repo.reason}</p>
        {/if}
        {#if repo.lastSyncAt}
          <p class="text-ink-meta text-[12px]">Last sync {formatTimestamp(repo.lastSyncAt)}</p>
        {:else}
          <p class="text-ink-meta text-[12px]">Not synced yet</p>
        {/if}
        {#if repo.lastError}
          <p class="text-warn-ink text-[12px]">{repo.lastError}</p>
        {/if}
      </div>

      {#if attention}
        <!-- Same handoff as the Today rows, offered where the user already
             came looking. `conflictSessionId` present ⇒ a resolver is already
             running; open it rather than starting a rival. -->
        <div class="border-paper-border bg-paper-card flex flex-col gap-2 rounded-lg border p-3">
          <p class="text-ink-body text-[13px]">{gitAttentionText(repo)}</p>
          <div>
            <Button variant="outline" size="sm" disabled={resolving} onclick={() => void resolve(repo)}>
              {repo.conflictSessionId ? 'Open session' : 'Resolve with agent'}
            </Button>
          </div>
        </div>
      {/if}

      <div class="flex flex-col gap-2">
        <p class="text-overline">Sync mode</p>
        <div role="radiogroup" aria-label="Sync mode" class="flex flex-col gap-0.5">
          {#each MODES as option (option.value)}
            {@const selected = repo.mode === option.value}
            <button
              type="button"
              role="radio"
              aria-checked={selected}
              disabled={saving}
              onclick={() => void chooseMode(option.value)}
              class="hover:bg-paper-pill flex items-start gap-2.5 rounded-md px-2 py-1.5 text-left transition-colors disabled:opacity-60"
            >
              <span
                class={[
                  'mt-[3px] flex size-3 shrink-0 items-center justify-center rounded-full border',
                  selected ? 'border-act' : 'border-paper-button-border'
                ]}
                aria-hidden="true"
              >
                {#if selected}
                  <span class="bg-act size-1.5 rounded-full"></span>
                {/if}
              </span>
              <span class="min-w-0">
                <span class="text-ink-heading block text-[13px]">{option.label}</span>
                <span class="text-ink-meta block text-[12px]">{option.description}</span>
              </span>
            </button>
          {/each}
        </div>
      </div>

      <div class="flex items-center gap-2">
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={syncing || saving || repo.mode === 'off'}
          onclick={() => void syncNow()}
        >
          {syncing ? 'Starting…' : 'Sync now'}
        </Button>
        {#if syncFlash}
          <span class="text-act-dot text-[12px]">Sync started</span>
        {/if}
        {#if repo.mode === 'off'}
          <span class="text-ink-meta text-[12px]">Turn sync on to run a pass.</span>
        {/if}
      </div>

      {#if error}
        <p class="text-warn-ink text-[12.5px]" role="alert">{error}</p>
      {/if}
    {/if}
  </Dialog.Content>
</Dialog.Root>
