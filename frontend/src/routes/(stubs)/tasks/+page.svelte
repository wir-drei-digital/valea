<script lang="ts">
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import ListTodo from '@lucide/svelte/icons/list-todo';
</script>

<AppFrame>
  {#snippet main()}
    <EmptyState
      icon={ListTodo}
      title="Open loops arrive in a later step."
      body="Tasks will gather here from mail, sessions, and workflows, with their sources attached."
    />
  {/snippet}
</AppFrame>
