<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import ListChecks from '@lucide/svelte/icons/list-checks';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={ListChecks}
      title="The audit log arrives in a later step."
      body="Every action — synced, drafted, approved — will be recorded here as plain JSON lines."
    />
  {/snippet}
</AppFrame>
