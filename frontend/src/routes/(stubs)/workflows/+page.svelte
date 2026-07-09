<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={RefreshCw}
      title="Workflows arrive in a later step."
      body="Every workflow is a YAML file you can read — triggers, steps, and approvals, nothing hidden."
    />
  {/snippet}
</AppFrame>
