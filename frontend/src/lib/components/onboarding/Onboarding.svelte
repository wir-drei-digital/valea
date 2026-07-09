<script lang="ts">
  // Welcome screen shown when no workspace is open (workspaceStore.state ===
  // 'none'). Per 2026-07-09 welcome mockup + DESIGN_SYSTEM.md §6 card
  // anatomy: two cards (start fresh / continue), trust bar footer, recent
  // workspaces list.
  import { Button } from '$lib/components/ui/button/index.js';
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

  async function openRecent(path: string) {
    openError = null;
    const result = await workspaceStore.open(path);
    if (!result.ok) {
      openError = "This folder doesn't look like a Valea workspace.";
    }
  }
</script>

<div class="mx-auto flex min-h-screen max-w-[880px] flex-col gap-10 px-8 py-16">
  <header class="flex flex-col gap-3 text-center">
    <h1 class="font-display text-[36px] leading-tight text-ink-heading">
      Welcome. Your business runs on a folder you own.
    </h1>
    <p class="mx-auto max-w-[560px] text-[14px] text-ink-subtitle">
      This app is a cockpit over plain files — your offers, policies, workflows and memory. No account to create.
      Choose how to begin:
    </p>
  </header>

  <div class="grid grid-cols-1 gap-5 md:grid-cols-2">
    <!-- Card 1: start fresh -->
    <section class="flex flex-col gap-4 rounded-xl border border-paper-border bg-paper-card p-5 shadow-card">
      <p class="text-overline text-act">START FRESH · MOST PEOPLE BEGIN HERE</p>
      <h2 class="font-display text-[19px] text-ink-heading">Set it up in conversation</h2>
      <p class="text-[13.5px] text-ink-body">
        About 15 minutes of talking. The assistant builds your workspace as you go, and you approve each page it
        writes.
      </p>

      <ol class="flex flex-col">
        {#each steps as step, i}
          <li
            class={[
              'flex items-start gap-3 py-3',
              i < steps.length - 1 ? 'border-b border-paper-hairline' : ''
            ]}
          >
            <span
              class="flex size-6 shrink-0 items-center justify-center rounded-full bg-paper-nav-active text-[11.5px] font-semibold text-ink-heading"
            >
              {i + 1}
            </span>
            <span class="pt-0.5 text-[13px] text-ink-body">{step}</span>
          </li>
        {/each}
      </ol>

      <div class="flex flex-wrap items-center gap-3 pt-1">
        <Button type="button" onclick={() => (createOpen = true)}>Start the conversation</Button>
        <span class="text-[12px] text-ink-meta">nothing connects without asking you</span>
      </div>
    </section>

    <!-- Card 2: continue -->
    <section class="flex flex-col gap-4 rounded-xl border border-paper-border bg-paper-panel p-5 shadow-card">
      <p class="text-overline">CONTINUE · FROM A HANDOFF OR BACKUP</p>
      <h2 class="font-display text-[19px] text-ink-heading">Open an existing workspace</h2>
      <p class="text-[13.5px] text-ink-body">
        From a consultant, a backup, or another machine. Everything picks up where it left off — memory, workflows,
        history.
      </p>

      <div
        class="flex flex-col items-center justify-center gap-2 rounded-lg border border-dashed border-paper-chip-border bg-paper-surface px-4 py-8 text-center"
      >
        <p class="text-[13.5px] font-semibold text-ink-heading">Drop your folder here</p>
        <p class="font-mono text-[11px] text-ink-meta">icm/ · workflows/ · queue/ · logs/</p>
        <p class="text-[12px] text-ink-subtitle">We'll show you what's inside before anything runs.</p>
      </div>

      <OpenWorkspaceFlow />
    </section>
  </div>

  {#if openError}
    <p role="alert" class="text-center text-[12.5px] text-warn-ink">{openError}</p>
  {/if}

  {#if workspaceStore.recent.length > 0}
    <div class="flex flex-col gap-2">
      <p class="text-overline">Recent</p>
      <ul class="flex flex-col">
        {#each workspaceStore.recent as ws (ws.path)}
          <li class="border-b border-paper-hairline last:border-b-0">
            <button
              type="button"
              onclick={() => openRecent(ws.path)}
              class="flex w-full items-center justify-between gap-3 py-2.5 text-left transition-colors hover:bg-paper-pill"
            >
              <span class="text-[13px] text-ink-body">{ws.name}</span>
              <span class="font-mono text-[11px] text-ink-meta">{ws.path}</span>
            </button>
          </li>
        {/each}
      </ul>
    </div>
  {/if}

  <TrustBar onExplain={() => (explainOpen = true)} />
</div>

<CreateWorkspaceDialog bind:open={createOpen} />
<WhatsInAWorkspace bind:open={explainOpen} />
