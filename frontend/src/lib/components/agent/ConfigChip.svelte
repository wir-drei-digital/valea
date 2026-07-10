<script lang="ts">
  // Compact composer chip for one `config` item (session config option — e.g.
  // permission mode, model). Opens a dropdown of item.options; selecting one
  // calls onSelect(value) — the parent (Composer) already knows which
  // config item this chip belongs to and forwards to
  // AgentSessionStore.setConfigOption(item.id, value).
  //
  // SECURITY: option/current names are agent/adapter-supplied strings.
  // Plain interpolation only, {@html} FORBIDDEN — same note as elsewhere
  // under agent/.
  import Check from '@lucide/svelte/icons/check';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import type { AcpItemLike } from './item-shapes';
  import { asStringOr, configOptions, configCurrent } from './item-shapes';

  let { item, onSelect }: { item: AcpItemLike; onSelect: (value: string) => void } = $props();

  const name = $derived(asStringOr(item.name, 'Option'));
  const options = $derived(configOptions(item));
  const current = $derived(configCurrent(item));
  const display = $derived(options.find((o) => o.id === current)?.name ?? current ?? '—');

  let open = $state(false);

  function choose(id: string) {
    open = false;
    if (id !== current) onSelect(id);
  }
</script>

{#if options.length > 0}
  <DropdownMenu.Root bind:open>
    <DropdownMenu.Trigger>
      {#snippet child({ props })}
        <button
          type="button"
          {...props}
          title={name}
          class="border-paper-chip-border bg-paper-card flex items-center gap-1 rounded-sm border px-2 py-1 text-[11.5px] text-ink-secondary hover:bg-paper-panel data-[state=open]:bg-paper-panel"
        >
          <span class="text-ink-meta">{name}</span>
          <span class="max-w-[12ch] truncate text-ink-body">{display}</span>
          <ChevronDown class="text-ink-meta size-3" aria-hidden="true" />
        </button>
      {/snippet}
    </DropdownMenu.Trigger>
    <DropdownMenu.Content align="start" class="w-[220px]">
      {#each options as option (option.id)}
        <DropdownMenu.Item onSelect={() => choose(option.id)}>
          <span class="min-w-0 flex-1 truncate">{option.name}</span>
          {#if option.id === current}
            <Check class="size-3.5" aria-hidden="true" />
          {/if}
        </DropdownMenu.Item>
      {/each}
    </DropdownMenu.Content>
  </DropdownMenu.Root>
{/if}
