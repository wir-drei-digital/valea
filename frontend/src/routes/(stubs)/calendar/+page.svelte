<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import Calendar from '@lucide/svelte/icons/calendar';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={Calendar}
      title="Calendar arrives in a later step."
      body="Your sessions will sync read-only from CalDAV or an ICS file."
    />
  {/snippet}
</AppFrame>
