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
          This app is a cockpit over plain files: your offers, policies, workflows and memory. No account to create.
          Choose how to begin:
        </p>
      </div>
    </header>

    <div class="grid grid-cols-1 gap-6 md:grid-cols-2">
      <!-- Card 1: start fresh -->
      <section class="border-paper-border bg-paper-card shadow-card flex flex-col gap-4 rounded-xl border p-6">
        <p class="text-overline text-act">START FRESH · MOST PEOPLE BEGIN HERE</p>
        <h2 class="font-display text-ink-heading text-[20px] font-medium">Create your first ICM</h2>
        <p class="text-ink-body text-[13.5px]">
          Give it a name and a folder. Valea creates a small starter project there, plain Markdown pages
          you own, and opens it straight into your first chat.
        </p>

        <ol class="flex flex-col">
          {#each ['A folder of Markdown pages, yours to keep', 'You choose where it lives, move it anytime', 'Chat with it right away, nothing connects without asking you'] as step, i}
            <li class={['flex items-start gap-3.5 py-3', i < 2 ? 'border-b border-paper-hairline' : '']}>
              <span class="text-ink-meta w-4 shrink-0 text-[13px] tabular-nums">{i + 1}</span>
              <span class="text-ink-body text-[13px] leading-relaxed">{step}</span>
            </li>
          {/each}
        </ol>

        <div class="mt-auto flex flex-wrap items-center gap-3 pt-1">
          <Button type="button" onclick={() => (createOpen = true)}>Start fresh</Button>
          <span class="text-ink-meta text-[12px]">takes under a minute</span>
        </div>
      </section>

      <!-- Card 2: use an existing ICM -->
      <section class="border-paper-border bg-paper-panel shadow-card flex flex-col gap-4 rounded-xl border p-6">
        <p class="text-overline">USE EXISTING ICM · BRING YOUR OWN FOLDER</p>
        <h2 class="font-display text-ink-heading text-[20px] font-medium">Use an existing ICM folder</h2>
        <p class="text-ink-body text-[13.5px]">
          From a consultant, a backup, or another machine. Point at the folder and we'll show you what's inside before
          anything mounts. Nothing is copied or moved; it stays exactly where it is.
        </p>

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
