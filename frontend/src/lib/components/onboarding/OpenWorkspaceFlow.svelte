<script lang="ts">
  // "Choose folder…" flow for the Continue card: pick a path, inspect it
  // before opening (per spec: "we'll show you what's inside before anything
  // runs"), then hand off to workspaceStore.open.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  type Inspection = {
    valid: boolean;
    icm_pages: number;
    workflows: number;
    queue_pending: number;
    has_audit_log: boolean;
  };

  let path = $state('');
  let inspecting = $state(false);
  let opening = $state(false);
  let error = $state<string | null>(null);
  let inspection = $state<Inspection | null>(null);

  const isTauri = typeof window !== 'undefined' && '__TAURI_INTERNALS__' in window;

  async function pickFolder() {
    const { open: openDialog } = await import('@tauri-apps/plugin-dialog');
    const selected = await openDialog({ directory: true });
    if (typeof selected === 'string') {
      path = selected;
      await inspect();
    }
  }

  async function inspect() {
    error = null;
    inspection = null;
    if (!path.trim()) {
      error = 'Choose a folder to open.';
      return;
    }

    inspecting = true;
    const result = await api.inspectWorkspace(path.trim());
    inspecting = false;

    if (!result.ok) {
      error = "This folder doesn't look like a Valea workspace.";
      return;
    }

    const data = result.data as Inspection;
    if (!data.valid) {
      error = "This folder doesn't look like a Valea workspace.";
      return;
    }

    inspection = data;
  }

  async function confirmOpen() {
    opening = true;
    const result = await workspaceStore.open(path.trim());
    opening = false;

    if (!result.ok) {
      error = "This folder doesn't look like a Valea workspace.";
      inspection = null;
      return;
    }
  }

  function cancel() {
    inspection = null;
    error = null;
  }
</script>

<div class="flex flex-col gap-3">
  {#if inspection}
    <div class="flex flex-col gap-3 rounded-lg border border-paper-border bg-paper-card p-4">
      <p class="font-mono text-[11.5px] text-ink-meta">{path}</p>
      <p class="text-[13px] text-ink-body">
        {inspection.icm_pages} memory pages · {inspection.workflows} workflows · {inspection.queue_pending} pending approvals
        · audit log {inspection.has_audit_log ? 'present' : 'missing'}
      </p>
      <div class="flex gap-2">
        <Button type="button" onclick={confirmOpen} disabled={opening}>
          {opening ? 'Opening…' : 'Open'}
        </Button>
        <Button type="button" variant="outline" onclick={cancel} disabled={opening}>Cancel</Button>
      </div>
    </div>
  {:else if isTauri}
    <Button type="button" variant="outline" onclick={pickFolder} disabled={inspecting}>
      {inspecting ? 'Checking…' : 'Choose folder…'}
    </Button>
  {:else}
    <div class="flex gap-2">
      <Input bind:value={path} disabled={inspecting} placeholder="/Users/you/Documents/my-business" />
      <Button type="button" variant="outline" onclick={inspect} disabled={inspecting}>
        {inspecting ? 'Checking…' : 'Choose folder…'}
      </Button>
    </div>
  {/if}

  {#if error}
    <p class="text-[12.5px] text-warn-ink">{error}</p>
  {/if}
</div>
