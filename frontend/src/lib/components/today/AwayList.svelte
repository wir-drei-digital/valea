<script lang="ts">
  import Check from '@lucide/svelte/icons/check';

  // Receipt rows (§8 dense queue rows): green check, 0.75 opacity — receipts,
  // not tasks. Strings render as-is; "· Undo" stays plain text this phase.
  let { items }: { items: string[] } = $props();
</script>

<ul class="flex flex-col gap-1.5">
  {#each items as item (item)}
    <li class="text-ink-secondary flex items-center gap-2 text-[13px] opacity-75">
      <Check class="text-act-dot size-3.5 shrink-0" aria-hidden="true" />
      {item}
    </li>
  {/each}
</ul>
