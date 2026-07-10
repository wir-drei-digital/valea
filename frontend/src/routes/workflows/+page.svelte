<script lang="ts">
  // Friendly card view over icm/Workflows/*.md (DESIGN_SYSTEM §11) — the
  // "trust story" counterpart to the Audit log: every automated thing this
  // assistant *could* do, as a readable contract, not a config file. Live
  // refresh rides `icm_changed` (workflow definitions are ICM pages) via the
  // single shared `workspace:events` join — see `wireIcmEvents`'s T20
  // carry-forward note in `icm.svelte.ts`; this route only needs the
  // first-load `refetch()`, same convention as `icmStore`/`queueStore` on
  // Today.
  import { onMount } from 'svelte';
  import { AppFrame, EmptyState } from '$lib/components/shell';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import { workflowsStore } from '$lib/stores/workflows.svelte';
  import WorkflowCard from '$lib/components/workflows/WorkflowCard.svelte';

  onMount(() => {
    void workflowsStore.refetch();
  });
</script>

<AppFrame>
  {#snippet main()}
    <header class="flex flex-col gap-2 pb-2">
      <h1 class="font-display text-ink-heading text-[24px]">Workflows</h1>
      <p class="text-ink-body max-w-[560px] text-[13.5px]">
        Every workflow is a plain file you can read — its trigger, its steps, and where it needs your
        approval, nothing hidden.
      </p>
    </header>

    {#if !workflowsStore.loaded}
      <div class="flex flex-col gap-4" aria-hidden="true">
        <Skeleton class="h-44 w-full rounded-xl" />
        <Skeleton class="h-44 w-full rounded-xl" />
      </div>
    {:else if workflowsStore.list.length === 0}
      <EmptyState
        icon={RefreshCw}
        title="No workflow contracts yet."
        body="Add a page under icm/Workflows/ with a trigger and risk level, and it shows up here."
      />
    {:else}
      <div class="flex flex-col gap-4">
        {#each workflowsStore.list as workflow (workflow.path)}
          <WorkflowCard {workflow} />
        {/each}
      </div>
    {/if}
  {/snippet}
</AppFrame>
