<script lang="ts">
  // Quiet ink-meta line under the transcript rendering whatever fields the
  // `usage` item's payload carries — see item-shapes.ts's usageFields() doc
  // for why there's no fixed schema and no derived math here.
  import type { AcpItemLike } from './item-shapes';
  import { usageFields } from './item-shapes';

  let { item }: { item: AcpItemLike | undefined } = $props();

  const fields = $derived(usageFields(item));
</script>

{#if fields.length > 0}
  <p class="text-ink-meta px-4 py-1 text-[11.5px]">
    {#each fields as field, i (field.label)}
      {#if i > 0}<span aria-hidden="true"> · </span>{/if}
      {field.label}: {field.value}
    {/each}
  </p>
{/if}
