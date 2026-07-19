<script lang="ts">
  // The receipts trail (DESIGN_SYSTEM §8 dense rows): every audited action —
  // synced, drafted, approved, permission decisions — reverse-chron, plain
  // sentences, nothing hidden. No live push keeps this fresh mid-session
  // (the queue-decision push listener that used to do so was removed
  // alongside the queue/workflow subsystem, Spec D deletion wave — see
  // `icm.svelte.ts`'s `wireIcmEvents` doc comment); this route only needs
  // the first-load `refetch()`.
  import { onMount } from 'svelte';
  import { AppFrame, EmptyState, PageHeader } from '$lib/components/shell';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import ListChecks from '@lucide/svelte/icons/list-checks';
  import { auditStore } from '$lib/stores/audit.svelte';
  import AuditRow from '$lib/components/audit/AuditRow.svelte';

  onMount(() => {
    void auditStore.refetch();
  });
</script>

<AppFrame>
  {#snippet main()}
    <PageHeader
      title="Audit log"
      subtitle="Every action is recorded here as plain lines, oldest at the bottom."
    />

    {#if !auditStore.loaded}
      <div class="flex flex-col gap-2" aria-hidden="true">
        <Skeleton class="h-9 w-full" />
        <Skeleton class="h-9 w-full" />
        <Skeleton class="h-9 w-full" />
      </div>
    {:else if auditStore.entries.length === 0}
      <EmptyState
        icon={ListChecks}
        title="Nothing recorded yet."
        body="Every action the assistant takes will show up here as a plain receipt."
      />
    {:else}
      <div class="flex flex-col">
        {#each auditStore.entries as entry, i (`${entry.ts}-${entry.type}-${i}`)}
          <AuditRow {entry} />
        {/each}
      </div>
    {/if}
  {/snippet}
</AppFrame>
