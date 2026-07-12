<script lang="ts">
  // Month grid for the calendar route: Monday-start weeks, hairline cells,
  // §9 event vocabulary at month density (mini chips instead of positioned
  // boxes). Out-month days are dimmed, today's cell carries the pill tint
  // and a terracotta day number (same accents as WeekGrid's today header),
  // and each cell is a button — picking a day hands it to the route, which
  // switches to the Day view.
  import {
    dayKey,
    isPastEvent,
    monthGridFor,
    timeLabel,
    type CalendarEvent
  } from './calendar-shapes';

  let {
    anchor,
    events,
    now,
    onSelectDay
  }: {
    anchor: Date;
    events: CalendarEvent[];
    now: Date;
    onSelectDay: (day: Date) => void;
  } = $props();

  const MAX_CHIPS = 3;
  const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  const weeks = $derived(monthGridFor(anchor));
  const todayKey = $derived(dayKey(now));

  function eventsFor(key: string): CalendarEvent[] {
    return events.filter((ev) => ev.day === key).sort((a, b) => a.startMin - b.startMin);
  }

  const CHIP_CLASS: Record<CalendarEvent['kind'], string> = {
    booked: 'border-l-2 border-act bg-act-tint text-ink-heading',
    block: 'bg-paper-track text-ink-secondary',
    hold: 'border border-dashed border-suggest-dash text-suggest-ink',
    routine: 'border border-act bg-paper-card text-ink-heading'
  };
</script>

<div>
  <div class="border-paper-hairline grid grid-cols-7 border-b pb-2">
    {#each WEEKDAYS as weekday (weekday)}
      <span class="text-ink-meta px-2.5 text-[11px]">{weekday}</span>
    {/each}
  </div>

  <div class="bg-paper-hairline grid grid-cols-7 gap-px">
    {#each weeks as week, w (w)}
      {#each week as day (dayKey(day))}
        {@const key = dayKey(day)}
        {@const inMonth = day.getMonth() === anchor.getMonth()}
        {@const isToday = key === todayKey}
        {@const dayEvents = eventsFor(key)}
        <!-- Cells stay opaque (a translucent cell lets the hairline gap
             color bleed through and reads darker, not dimmer) — out-month
             days dim their CONTENT instead. -->
        <button
          type="button"
          class={[
            'flex min-h-[92px] flex-col items-stretch gap-1 px-1.5 pt-1.5 pb-2 text-left transition-colors',
            isToday ? 'bg-paper-pill' : 'bg-paper-surface hover:bg-paper-panel'
          ]}
          onclick={() => onSelectDay(day)}
          aria-label={`Open ${key}`}
        >
          <span
            class={[
              'px-1 text-[11.5px] tabular-nums',
              isToday ? 'text-warn-ink font-semibold' : inMonth ? 'text-ink-secondary' : 'text-ink-meta'
            ]}
          >
            {day.getDate()}
          </span>
          {#each dayEvents.slice(0, MAX_CHIPS) as event (event.id)}
            <span
              class={[
                'truncate rounded-[5px] px-1.5 py-0.5 text-[10.5px] leading-snug',
                CHIP_CLASS[event.kind],
                (isPastEvent(event, now) || !inMonth) && 'opacity-55'
              ]}
              title={`${timeLabel(event.startMin)} ${event.title}`}
            >
              {event.title}
            </span>
          {/each}
          {#if dayEvents.length > MAX_CHIPS}
            <span class="text-ink-meta px-1 text-[10.5px]">+{dayEvents.length - MAX_CHIPS} more</span>
          {/if}
        </button>
      {/each}
    {/each}
  </div>
</div>
