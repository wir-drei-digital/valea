<script lang="ts">
  // The receipts trail (DESIGN_SYSTEM §8 dense rows): every audited action —
  // synced, drafted, approved, permission decisions — reverse-chron, plain
  // sentences, nothing hidden. Live refresh rides `queue_changed` via the
  // single shared `workspace:events` join (`wireAuditEvents`, wired from
  // `wireIcmEvents` in `icm.svelte.ts`); this route only needs the
  // first-load `refetch()`.
  import { onMount } from 'svelte';
  import { AppFrame, EmptyState } from '$lib/components/shell';
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
    <header class="flex flex-col gap-2 pb-2">
      <h1 class="font-display text-ink-heading text-[24px]">Audit log</h1>
      <p class="text-ink-body max-w-[560px] text-[13.5px]">
        Every action — synced, drafted, approved — recorded here as plain lines, oldest at the bottom.
      </p>
    </header>

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
        body="Every action the assistant takes — synced, drafted, approved — will show up here as a plain receipt."
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
