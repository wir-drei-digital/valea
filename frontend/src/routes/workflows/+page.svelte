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
  import { AppFrame, EmptyState, PageHeader } from '$lib/components/shell';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import RefreshCw from '@lucide/svelte/icons/refresh-cw';
  import { workflowsStore } from '$lib/stores/workflows.svelte';
  import WorkflowCard from '$lib/components/workflows/WorkflowCard.svelte';
  import { api } from '$lib/api/client';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { normalizeCockpitToday } from '$lib/today/cockpit';
  import { distillButtonState, distillErrorMessage, type DistillPhase } from '$lib/today/distill';

  // "Distill recent decisions" (Task B13) — same action as the Today page's,
  // rendered on whichever card's `resolvedPath` matches the cockpit
  // payload's `distillWorkflowPath` (Task B8 — still a bare absolute-path
  // string; `Valea.Workflows.distill_path/0` returns `resolved_path`, see
  // its Task 7.1 doc). This route otherwise never fetches cockpit data, so
  // a small standalone fetch on mount is enough — the field is the only
  // thing this page needs off that payload.
  let distillWorkflowPath: string | null = $state(null);
  let distillPhase: DistillPhase = $state('idle');
  let distillSessionId: string | null = $state(null);
  let distillErrorText: string | undefined = $state(undefined);

  async function loadDistillWorkflowPath(): Promise<void> {
    const result = await api.cockpitToday();
    if (result.ok) {
      distillWorkflowPath = normalizeCockpitToday(result.data as Record<string, any>).distillWorkflowPath;
    }
  }

  const distillState = $derived(distillButtonState({ distillWorkflowPath }, distillPhase, distillErrorText));

  async function runDistill(): Promise<void> {
    if (!distillWorkflowPath) return; // defensive: the button is hidden whenever this is null
    distillPhase = 'running';
    distillErrorText = undefined;
    const result = await api.distillDecisions(workspaceStore.generation ?? 0);
    if (result.ok) {
      const data = result.data as { runId: string; sessionId: string };
      distillSessionId = data.sessionId;
    } else if (result.error === 'no_recent_decisions') {
      distillPhase = 'empty';
    } else {
      distillPhase = 'error';
      distillErrorText = distillErrorMessage(result.error);
    }
  }

  onMount(() => {
    void workflowsStore.refetch();
    void loadDistillWorkflowPath();
  });
</script>

<AppFrame>
  {#snippet main()}
    <PageHeader
      title="Workflows"
      subtitle="Every workflow is a plain file you can read — its trigger, its steps, and where it needs your approval, nothing hidden."
    />

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
        {#each workflowsStore.list as workflow (workflow.icmId + workflow.relativePath)}
          <div class="flex flex-col gap-2.5">
            <WorkflowCard {workflow} />
            {#if workflow.resolvedPath === distillWorkflowPath && distillState.visible}
              <div class="flex flex-wrap items-center gap-2.5 px-1">
                <Button
                  variant="outline"
                  size="sm"
                  disabled={distillState.disabled}
                  onclick={() => void runDistill()}
                >
                  {distillState.label}
                </Button>
                {#if distillPhase === 'running' && distillSessionId}
                  <a
                    href={`/chat?session=${distillSessionId}`}
                    class="text-act hover:text-act-hover text-[12.5px] font-semibold"
                  >
                    Watching the run &rarr;
                  </a>
                {/if}
                {#if distillState.note}
                  <p class="text-[12.5px] {distillPhase === 'error' ? 'text-warn-ink' : 'text-ink-meta'}">
                    {distillState.note}
                  </p>
                {/if}
              </div>
            {/if}
          </div>
        {/each}
      </div>
    {/if}
  {/snippet}
</AppFrame>
