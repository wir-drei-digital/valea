<script lang="ts">
  // Connection preflight for the mail account (mail design spec §Account
  // setup + doctor; Task 17). Same presentation pattern as the Phase-3
  // `agent/DoctorPanel.svelte` — check-row markup/classes reused verbatim
  // (status icon, detail one toggle away via the remedy's copy button) —
  // except the label comes straight off the check payload (`check.label`)
  // rather than a hardcoded id->label map: `Valea.Mail.Doctor.run/1`
  // already emits a human `label` per check (unlike the agent harness
  // doctor's four-key shape), so there's no separate lookup table to keep
  // in sync as checks are added (`workflow_contract` etc.).
  //
  // Backend contract: `Valea.Mail.Doctor.run/1` via `api.mailDoctor(generation)`
  // — a SEQUENTIAL pipeline (config_present -> credential_present ->
  // tcp_reachable -> tls_ok/login_ok/folders/move_capability ->
  // workflow_contract), each `{id, label, status, detail, remedy}`.
  // `status` is "ok" | "failed" | "unknown" ("unknown" means an earlier
  // check in the chain failed, so this one was never attempted — never
  // rendered as a false "broken" claim). `remedy` is only ever present on a
  // "failed" check.
  //
  // "Create AI folders" (visible once the `folders` check has actually
  // failed, per `foldersCheckFailed`) calls `api.createMailFolders(generation)`
  // then re-runs the doctor — same self-contained "mount + re-run" shape as
  // DoctorPanel's "Check again", just with an extra action button beside it.
  import { onMount } from 'svelte';
  import Check from '@lucide/svelte/icons/check';
  import X from '@lucide/svelte/icons/x';
  import CircleHelp from '@lucide/svelte/icons/circle-help';
  import Copy from '@lucide/svelte/icons/copy';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { normalizeMailDoctorChecks, foldersCheckFailed, type MailDoctorCheck } from './mail-shapes';

  let { generation }: { generation: number } = $props();

  let checks: MailDoctorCheck[] = $state([]);
  let loading = $state(true);
  let loadFailed = $state(false);
  let copiedId: string | null = $state(null);
  let creatingFolders = $state(false);

  const showCreateFolders = $derived(foldersCheckFailed(checks));

  async function run(): Promise<void> {
    loading = true;
    loadFailed = false;
    const result = await api.mailDoctor(generation);
    if (result.ok) {
      const data = result.data as { ok: boolean; checks: unknown };
      checks = normalizeMailDoctorChecks(data.checks);
    } else {
      loadFailed = true;
    }
    loading = false;
  }

  onMount(() => {
    void run();
  });

  async function copy(id: string, remedy: string): Promise<void> {
    await navigator.clipboard.writeText(remedy);
    copiedId = id;
    setTimeout(() => {
      if (copiedId === id) copiedId = null;
    }, 1500);
  }

  async function createFolders(): Promise<void> {
    creatingFolders = true;
    await api.createMailFolders(generation);
    creatingFolders = false;
    void run();
  }
</script>

<div class="flex flex-col gap-4 py-2">
  <div class="flex flex-col gap-1.5">
    <h2 class="font-display text-[19px] text-ink-heading">Checking your mailbox</h2>
    <p class="max-w-[480px] text-[13px] text-ink-body">
      Connectivity, sign-in, and folder setup for your mail account.
    </p>
  </div>

  {#if loading}
    <p class="text-ink-meta text-[13px]">Running checks…</p>
  {:else if loadFailed}
    <p class="text-warn-ink text-[13px]">Couldn't run the checks just now. Try again in a moment.</p>
  {:else}
    <ul class="flex flex-col gap-2.5">
      {#each checks as check (check.id)}
        <li class="border-paper-border bg-paper-card rounded-xl border px-4 py-3">
          <div class="flex items-center gap-2.5">
            <span class="flex size-4 shrink-0 items-center justify-center" aria-hidden="true">
              {#if check.status === 'ok'}
                <Check class="text-act-dot size-4" />
              {:else if check.status === 'failed'}
                <X class="text-warn-ink size-4" />
              {:else}
                <CircleHelp class="text-suggest-ink size-4" />
              {/if}
            </span>
            <span class="text-[13.5px] font-medium text-ink-heading">
              {check.label}
            </span>
          </div>
          <p class="mt-1 pl-[26px] text-[12.5px] text-ink-body">{check.detail}</p>
          {#if check.remedy}
            <div class="mt-2 ml-[26px] flex items-center gap-2 rounded-lg bg-paper-pill px-3 py-2">
              <code class="min-w-0 flex-1 truncate font-mono text-[11.5px] text-ink-secondary">
                {check.remedy}
              </code>
              <button
                type="button"
                onclick={() => copy(check.id, check.remedy as string)}
                class="text-ink-meta hover:text-ink-heading shrink-0"
              >
                {#if copiedId === check.id}
                  <span class="text-act-dot text-[11px]">Copied</span>
                {:else}
                  <Copy class="size-3.5" aria-label="Copy remedy" />
                {/if}
              </button>
            </div>
          {/if}
        </li>
      {/each}
    </ul>
  {/if}

  <div class="flex items-center gap-2">
    <Button type="button" variant="outline" size="sm" onclick={() => run()} disabled={loading}>
      Check again
    </Button>
    {#if showCreateFolders}
      <Button type="button" size="sm" onclick={() => void createFolders()} disabled={creatingFolders}>
        {creatingFolders ? 'Creating…' : 'Create AI folders'}
      </Button>
    {/if}
  </div>
</div>
