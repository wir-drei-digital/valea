<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import Mail from '@lucide/svelte/icons/mail';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={Mail}
      title="Mail arrives in a later step."
      body="Your inbox will connect over IMAP — drafts only, nothing sends without you."
    />
  {/snippet}
</AppFrame>
