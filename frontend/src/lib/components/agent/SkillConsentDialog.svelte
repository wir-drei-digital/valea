<script lang="ts">
  // The consent step for installing or updating an ICM skill (ICM skills
  // design spec §Frontend). Confirming here IS the consent — the RPC is
  // control-token-gated and generation-guarded, and this dialog is the one
  // place a user grants the write. Shared by `SkillsPanel.svelte` (the agent
  // settings modal) and `SkillsOfferCard.svelte` (the sidebar offer, Task
  // 11): both hand it a `SkillRow` plus the mount it belongs to.
  //
  // The primary button ALWAYS names the outcome ("Install into {mountName}",
  // "Replace my edited copy") — never a bare "Update" — so the user reads
  // exactly what confirming does, per the product copy rules.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import type { SkillRow } from './skills-rows';

  let {
    open = $bindable(false),
    mode,
    row,
    mountKey,
    mountName,
    edited,
    onDone
  }: {
    open?: boolean;
    mode: 'install' | 'update';
    row: SkillRow;
    mountKey: string;
    mountName: string;
    edited: boolean;
    onDone: () => void;
  } = $props();

  let submitting = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    if (open) {
      submitting = false;
      error = null;
    }
  });

  const title = $derived(
    mode === 'install' ? `Install ${row.name} into ${mountName}?` : `Update ${row.name} in ${mountName}?`
  );

  // Edited installs never get a bare "Update" — the label spells out that
  // confirming discards the user's own changes.
  const confirmLabel = $derived(
    mode === 'install' ? `Install into ${mountName}` : edited ? 'Replace my edited copy' : `Update ${row.name}`
  );

  async function confirm(): Promise<void> {
    submitting = true;
    error = null;
    const generation = workspaceStore.generation ?? 0;

    const result =
      mode === 'install'
        ? await api.installSkill({ mountKey, skillId: row.skillId, generation })
        : await api.updateSkill({ mountKey, skillId: row.skillId, force: edited, generation });

    submitting = false;

    if (!result.ok) {
      error =
        mode === 'install'
          ? "Couldn't install the skill. Try again in a moment."
          : "Couldn't update the skill. Try again in a moment.";
      return;
    }

    open = false;
    onDone();
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">{title}</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        {#if mode === 'install'}
          Adds its files under <code class="font-mono text-[12px]">.claude/skills/{row.skillId}/</code> in
          your ICM folder. It teaches your assistant how to structure this ICM's folders and add new
          workflow documents. After installing, the files are yours — readable, editable, and they travel
          with the folder.
        {:else}
          Replaces the installed files under
          <code class="font-mono text-[12px]">.claude/skills/{row.skillId}/</code> with the latest pinned
          snapshot ({row.installedVersion ?? 'installed'} → {row.pinned ?? 'latest'}).
        {/if}
      </Dialog.Description>
    </Dialog.Header>

    <div class="flex flex-col gap-2">
      {#if row.sourceUrl}
        <p class="text-ink-meta text-[12px]">
          Source: {row.sourceUrl}{#if row.license}&nbsp;({row.license}){/if}.
        </p>
      {/if}

      {#if mode === 'update' && edited}
        <p role="alert" class="text-warn-ink text-[12.5px]">
          You have edited this skill. Updating replaces your changes.
        </p>
      {/if}

      {#if error}
        <p role="alert" class="text-warn-ink text-[12.5px]">{error}</p>
      {/if}
    </div>

    <Dialog.Footer>
      <Button type="button" variant="ghost" onclick={() => (open = false)} disabled={submitting}>
        Not now
      </Button>
      <Button type="button" onclick={() => void confirm()} disabled={submitting}>
        {submitting ? 'Working…' : confirmLabel}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
