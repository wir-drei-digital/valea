<script lang="ts">
  // Welcome screen shown when no workspace is open (workspaceStore.state ===
  // 'none'). Per 2026-07-09 welcome mockup + DESIGN_SYSTEM.md §6 card
  // anatomy: two cards (start fresh / continue), trust bar footer, recent
  // workspaces list.
  import { Button } from '$lib/components/ui/button/index.js';
  import Folder from '@lucide/svelte/icons/folder';
  import CreateWorkspaceDialog from './CreateWorkspaceDialog.svelte';
  import OpenWorkspaceFlow from './OpenWorkspaceFlow.svelte';
  import TrustBar from './TrustBar.svelte';
  import WhatsInAWorkspace from './WhatsInAWorkspace.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let createOpen = $state(false);
  let explainOpen = $state(false);
  let openError = $state<string | null>(null);

  const steps = [
    'Connect email & calendar — Gmail, Microsoft 365, Infomaniak, or any IMAP / CalDAV',
    'Tell it about your offers, prices and how you write',
    "Pick your first workflow — it drafts, you approve"
  ];

  async function openRecent(id: string) {
    openError = null;
    const result = await workspaceStore.open(id);
    if (!result.ok) {
      openError = "This folder doesn't look like a Valea workspace.";
    }
  }
</script>

<div class="flex min-h-screen flex-col">
  <div class="mx-auto flex w-full max-w-[1010px] flex-1 flex-col justify-center gap-10 px-8 py-14">
    <header class="flex flex-col items-center gap-6 text-center">
      <div
        class="bg-act flex size-14 items-center justify-center rounded-[15px] shadow-[0_10px_24px_rgba(47,93,72,0.28)]"
        aria-hidden="true"
      >
        <Folder class="size-6 text-white" strokeWidth={1.75} />
      </div>
      <div class="flex flex-col gap-3">
        <h1 class="font-display text-ink-heading text-[38px] leading-[1.15] font-medium text-balance">
          Welcome. Your business runs on a folder you own.
        </h1>
        <p class="text-ink-subtitle mx-auto max-w-[560px] text-[14.5px] leading-relaxed">
          This app is a cockpit over plain files — your offers, policies, workflows and memory. No account to create.
          Choose how to begin:
        </p>
      </div>
    </header>

    <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
      <!-- Card 1: start fresh -->
      <section class="border-paper-border bg-paper-card shadow-card flex flex-col gap-4 rounded-xl border p-6">
        <p class="text-overline text-act">START FRESH · MOST PEOPLE BEGIN HERE</p>
        <h2 class="font-display text-ink-heading text-[20px] font-medium">Set it up in conversation</h2>
        <p class="text-ink-body text-[13.5px]">
          About 15 minutes of talking. The assistant builds your workspace as you go, and you approve each page it
          writes.
        </p>

        <ol class="flex flex-col">
          {#each steps as step, i}
            <li
              class={[
                'flex items-start gap-3.5 py-3',
                i < steps.length - 1 ? 'border-b border-paper-hairline' : ''
              ]}
            >
              <span class="text-ink-meta w-4 shrink-0 text-[13px] tabular-nums">{i + 1}</span>
              <span class="text-ink-body text-[13px] leading-relaxed">{step}</span>
            </li>
          {/each}
        </ol>

        <div class="mt-auto flex flex-wrap items-center gap-3 pt-1">
          <Button type="button" onclick={() => (createOpen = true)}>Start the conversation</Button>
          <span class="text-ink-meta text-[12px]">nothing connects without asking you</span>
        </div>
      </section>

      <!-- Card 2: continue -->
      <section class="border-paper-border bg-paper-panel shadow-card flex flex-col gap-4 rounded-xl border p-6">
        <p class="text-overline">CONTINUE · FROM A HANDOFF OR BACKUP</p>
        <h2 class="font-display text-ink-heading text-[20px] font-medium">Open an existing workspace</h2>
        <p class="text-ink-body text-[13.5px]">
          From a consultant, a backup, or another machine. Everything picks up where it left off — memory, workflows,
          history.
        </p>

        <div
          class="border-paper-chip-border bg-paper-surface flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed px-4 py-9 text-center"
        >
          <p class="text-ink-heading text-[13.5px] font-semibold">Drop your folder here</p>
          <p class="text-ink-meta font-mono text-[11px]">icm/ · workflows/ · queue/ · logs/</p>
          <p class="text-ink-subtitle text-[12px]">We'll show you what's inside before anything runs.</p>
        </div>

        <div class="mt-auto">
          <OpenWorkspaceFlow />
        </div>
      </section>
    </div>

    {#if openError}
      <p role="alert" class="text-warn-ink text-center text-[12.5px]">{openError}</p>
    {/if}

    {#if workspaceStore.recent.length > 0}
      <div class="flex flex-col gap-2">
        <p class="text-overline">Recent</p>
        <ul class="flex flex-col">
          {#each workspaceStore.recent as ws (ws.id)}
            <li class="border-paper-hairline border-b last:border-b-0">
              <button
                type="button"
                onclick={() => openRecent(ws.id)}
                class="hover:bg-paper-pill flex w-full items-center justify-between gap-3 py-2.5 text-left transition-colors"
              >
                <span class="text-ink-body text-[13px]">{ws.name}</span>
              </button>
            </li>
          {/each}
        </ul>
      </div>
    {/if}
  </div>

  <TrustBar onExplain={() => (explainOpen = true)} />
</div>

<CreateWorkspaceDialog bind:open={createOpen} />
<WhatsInAWorkspace bind:open={explainOpen} />
