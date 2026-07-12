<script lang="ts">
  // The knowledge pane's header action: one outline button opening a small
  // page/folder menu — same header-action slot Mail's "Sync now" and Chat's
  // "New session" occupy, replacing the old two-button pane footer.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';

  let { onNew }: { onNew: (mode: 'page' | 'folder') => void } = $props();
</script>

<DropdownMenu.Root>
  <DropdownMenu.Trigger>
    {#snippet child({ props })}
      <Button type="button" variant="outline" size="sm" {...props}>
        New
        <ChevronDown class="text-ink-meta" aria-hidden="true" />
      </Button>
    {/snippet}
  </DropdownMenu.Trigger>
  <DropdownMenu.Content align="end" class="w-40">
    <DropdownMenu.Item onSelect={() => onNew('page')}>New page</DropdownMenu.Item>
    <DropdownMenu.Item onSelect={() => onNew('folder')}>New folder</DropdownMenu.Item>
  </DropdownMenu.Content>
</DropdownMenu.Root>
