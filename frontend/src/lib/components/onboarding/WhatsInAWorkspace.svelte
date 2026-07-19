<script lang="ts">
  // Plain explanation of the workspace folder structure, opened from the
  // trust bar's ">_ What's in a workspace?" link. Product voice: calm,
  // factual, no exclamation marks or emoji (DESIGN_SYSTEM.md §1/§3).
  import * as Dialog from '$lib/components/ui/dialog/index.js';

  let { open = $bindable(false) }: { open?: boolean } = $props();
</script>

<Dialog.Root bind:open>
  <Dialog.Content class="sm:max-w-md">
    <Dialog.Header>
      <Dialog.Title class="font-display text-[19px] text-ink-heading">What's in a workspace?</Dialog.Title>
      <Dialog.Description class="text-ink-body">
        A workspace is a folder on this Mac. Everything the app knows about your business lives inside it, as plain
        files.
      </Dialog.Description>
    </Dialog.Header>

    <dl class="flex flex-col gap-3 text-[13px]">
      <div class="flex flex-col gap-0.5">
        <dt class="font-mono text-[11.5px] text-ink-meta">icm/</dt>
        <dd class="text-ink-body">Your business memory, written as Markdown pages: offers, policies, clients.</dd>
      </div>
      <div class="flex flex-col gap-0.5">
        <dt class="font-mono text-[11.5px] text-ink-meta">workflows/</dt>
        <dd class="text-ink-body">The routines the assistant follows, as inspectable YAML.</dd>
      </div>
      <div class="flex flex-col gap-0.5">
        <dt class="font-mono text-[11.5px] text-ink-meta">queue/</dt>
        <dd class="text-ink-body">Approvals waiting on you, kept as files until you decide.</dd>
      </div>
      <div class="flex flex-col gap-0.5">
        <dt class="font-mono text-[11.5px] text-ink-meta">logs/audit.jsonl</dt>
        <dd class="text-ink-body">A record of every action taken, in order.</dd>
      </div>
    </dl>

    <p class="text-ink-secondary">
      These are plain files you can open, export, back up, or hand to someone else at any time.
    </p>
  </Dialog.Content>
</Dialog.Root>
