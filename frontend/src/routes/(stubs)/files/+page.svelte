<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import Folder from '@lucide/svelte/icons/folder';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={Folder}
      title="Files arrive in a later step."
      body="Browse everything in your workspace folder — it's yours."
    />
  {/snippet}
</AppFrame>
