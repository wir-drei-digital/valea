<script lang="ts">
  import type { ScheduleItem } from '$lib/today/cockpit';

  let { items }: { items: ScheduleItem[] } = $props();

  // Phase 1 heuristic: the seeded narrative marks booked sessions with a prep
  // status; a real-event flag arrives with live calendar data (§9 event
  // vocabulary: solid + 3px green left bar = real).
  function isRealEvent(item: ScheduleItem): boolean {
    return item.status === 'prep_ready' || item.status === 'prep_at_14';
  }
</script>

<ul class="flex flex-col">
  {#each items as item (item.time + item.title)}
    <li class="flex items-start gap-3 py-2.5">
      <span class="text-ink-meta w-10 shrink-0 pt-px font-mono text-[11.5px]">{item.time}</span>
      <span
        class="mt-0.5 h-9 w-[3px] shrink-0 rounded-full {isRealEvent(item) ? 'bg-act' : 'bg-transparent'}"
        aria-hidden="true"
      ></span>
      <div class="min-w-0 flex-1">
        <div class="flex items-center gap-2">
          <p class="text-ink-heading truncate text-[13.5px] [font-weight:650]">{item.title}</p>
          {#if item.status === 'prep_ready'}
            <span
              class="bg-act-tint text-act shrink-0 rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
            >
              Prep ready
            </span>
          {:else if item.status === 'prep_at_14'}
            <span
              class="bg-paper-track text-ink-secondary shrink-0 rounded-full px-2 py-0.5 text-[10.5px] font-bold tracking-[0.04em] uppercase"
            >
              Prep at 14:00
            </span>
          {/if}
        </div>
        {#if item.subtitle}
          <p
            class="text-[12.5px] {item.status === 'current'
              ? 'text-ink-secondary font-medium'
              : 'text-ink-subtitle'}"
          >
            {item.subtitle}
          </p>
        {/if}
      </div>
    </li>
  {/each}
</ul>
