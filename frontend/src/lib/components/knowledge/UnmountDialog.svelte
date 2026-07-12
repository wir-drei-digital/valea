<script lang="ts">
  // "Unmount" confirmation for an EXTERNAL (by-reference, A2-T8/A2-T9)
  // mount — config-only, same never-delete posture `DeleteDialog.svelte`
  // states for a page/folder, but stronger here: unmounting doesn't even
  // touch the folder's CONTENTS, only this workspace's reference to it (see
  // `Valea.Mounts.undeclare/2`'s moduledoc — "NEVER touches any folder").
  // One instance lives at the Knowledge page level; every "Unmount" button
  // (active section header, degraded chip, deactivated row) sets `name`
  // and opens it, mirroring `DeleteDialog`'s per-row-props pattern.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { mountsStore, undeclareMountErrorMessage } from '$lib/stores/mounts.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let { name, open = $bindable(false) }: { name: string; open?: boolean } = $props();

  let submitting = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    if (open) {
      submitting = false;
      error = null;
    }
  });

  async function submit() {
    submitting = true;
    const result = await mountsStore.undeclare(name, workspaceStore.generation ?? 0);
    submitting = false;

    if (!result.ok) {
      error = undeclareMountErrorMessage(result.error);
      return;
    }

    open = false;
  }
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-sm">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">Unmount "{name}"?</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        This removes it from this workspace's mount list — the folder stays exactly where it is on disk. Nothing
        is deleted, moved, or copied.
      </Dialog.Description>
    </Dialog.Header>

    {#if error}
      <p role="alert" class="text-[12.5px] text-warn-ink">{error}</p>
    {/if}

    <Dialog.Footer>
      <Button type="button" variant="outline" onclick={() => (open = false)} disabled={submitting}>Cancel</Button>
      <Button
        type="button"
        variant="outline"
        class="border-warn-border text-warn-ink hover:bg-warn-tint hover:text-warn-ink"
        onclick={submit}
        disabled={submitting}
      >
        {submitting ? 'Unmounting…' : 'Unmount'}
      </Button>
    </Dialog.Footer>
  </Dialog.Content>
</Dialog.Root>
