<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import Plug from '@lucide/svelte/icons/plug';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={Plug}
      title="Sources arrive in a later step."
      body="Mail and calendar connections will be managed here."
    />
  {/snippet}
</AppFrame>
