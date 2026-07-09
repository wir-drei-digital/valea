<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import MessageSquare from '@lucide/svelte/icons/message-square';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={MessageSquare}
      title="Chat arrives in a later step."
      body="You'll talk to an assistant that reads your business memory and asks before acting."
    />
  {/snippet}
</AppFrame>
