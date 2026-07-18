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
    type AllDayEntry,
    type CalendarEvent
  } from './calendar-shapes';

  let {
    anchor,
    events,
    now,
    onSelectDay,
    allDay = [],
    onSelect
  }: {
    anchor: Date;
    events: CalendarEvent[];
    now: Date;
    onSelectDay: (day: Date) => void;
    /** Spec F all-day entries — rendered first in each cell's chip stack. */
    allDay?: AllDayEntry[];
    /**
     * Selection callback (Spec F). Month cells are already buttons (day
     * drill-down), so chips report selection via a bubbling-stopped click
     * on the chip span; keyboard selection happens in the day/week views.
     */
    onSelect?: (id: string) => void;
  } = $props();

  const MAX_CHIPS = 3;
  const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  const weeks = $derived(monthGridFor(anchor));
  const todayKey = $derived(dayKey(now));

  /** One cell's chip stack: all-day chips first, then timed, one flat list for the cap. */
  type Chip = { id: string; title: string; kind: CalendarEvent['kind']; cancelled: boolean; time: string | null; past: boolean };

  function chipsFor(key: string): Chip[] {
    const allDayChips = allDay
      .filter((entry) => entry.day === key)
      .map((entry) => ({
        id: entry.id,
        title: entry.title,
        kind: entry.kind,
        cancelled: entry.cancelled,
        time: null,
        past: key < todayKey
      }));
    const timedChips = events
      .filter((ev) => ev.day === key)
      .sort((a, b) => a.startMin - b.startMin)
      .map((ev) => ({
        id: ev.id,
        title: ev.title,
        kind: ev.kind,
        cancelled: ev.cancelled === true,
        time: timeLabel(ev.startMin),
        past: isPastEvent(ev, now)
      }));
    return [...allDayChips, ...timedChips];
  }

  function selectChip(eventClick: MouseEvent, id: string): void {
    if (!onSelect) return;
    eventClick.stopPropagation();
    onSelect(id);
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
        {@const dayChips = chipsFor(key)}
        <!-- Cells stay opaque (a translucent cell lets the hairline gap
             color bleed through and reads darker, not dimmer) — out-month
             days dim their CONTENT instead. The cell itself is a plain div
             so chips can be REAL buttons (Spec F selection) without nested
             interactives; the day number is the day-view drill-down. -->
        <div
          class={[
            'flex min-h-[92px] flex-col items-stretch gap-1 px-1.5 pt-1.5 pb-2 text-left transition-colors',
            isToday ? 'bg-paper-pill' : 'bg-paper-surface hover:bg-paper-panel'
          ]}
        >
          <button
            type="button"
            class={[
              'w-fit px-1 text-left text-[11.5px] tabular-nums',
              isToday ? 'text-warn-ink font-semibold' : inMonth ? 'text-ink-secondary' : 'text-ink-meta'
            ]}
            onclick={() => onSelectDay(day)}
            aria-label={`Open ${key}`}
          >
            {day.getDate()}
          </button>
          {#each dayChips.slice(0, MAX_CHIPS) as chip (chip.id)}
            <svelte:element
              this={onSelect ? 'button' : 'span'}
              {...onSelect ? { type: 'button', onclick: (e: MouseEvent) => selectChip(e, chip.id) } : {}}
              class={[
                'truncate rounded-[5px] px-1.5 py-0.5 text-left text-[10.5px] leading-snug',
                CHIP_CLASS[chip.kind],
                (chip.past || !inMonth) && 'opacity-55',
                chip.cancelled && 'line-through opacity-70'
              ]}
              title={chip.time ? `${chip.time} ${chip.title}` : chip.title}
            >
              {chip.title}
            </svelte:element>
          {/each}
          {#if dayChips.length > MAX_CHIPS}
            <span class="text-ink-meta px-1 text-[10.5px]">+{dayChips.length - MAX_CHIPS} more</span>
          {/if}
        </div>
      {/each}
    {/each}
  </div>
</div>
