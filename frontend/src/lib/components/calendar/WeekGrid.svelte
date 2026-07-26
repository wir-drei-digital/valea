<script lang="ts">
  // Time grid for the calendar route: hour gutter + one column per visible
  // day, hairline hour lines, today header highlight, absolutely
  // positioned EventCards, and the terracotta now-line (§9: today's column
  // only). Presentational — the route owns which days are visible; this
  // component derives the hour window from whatever events fall on them.
  import {
    dayHeaderParts,
    dayKey,
    eventBox,
    gutterHours,
    isPastEvent,
    minutesOfDay,
    nowOffsetPct,
    timeLabel,
    type AllDayEntry,
    type CalendarEvent
  } from './calendar-shapes';
  import EventCard from './EventCard.svelte';

  let {
    days,
    events,
    now,
    allDay = [],
    onSelect,
    onCreateSlot
  }: {
    days: Date[];
    events: CalendarEvent[];
    now: Date;
    /** Spec F all-day lane entries — a chip row between header and time grid. */
    allDay?: AllDayEntry[];
    /** Selection callback (Spec F): grid events and all-day chips report their `id`. */
    onSelect?: (id: string) => void;
    /** Clicking an empty slot: the day plus the (30-minute-snapped) minutes-of-day the click landed on. */
    onCreateSlot?: (day: Date, minutes: number) => void;
  } = $props();

  // 64px per hour — roomy enough for a title + time line on a 45-minute event.
  const HOUR_PX = 64;

  // The grid shows the FULL day, midnight to midnight — the page's own
  // scroll container carries the height; `morningAnchor` below scrolls the
  // working hours into view so nobody lands on 00:00.
  const window = { startMin: 0, endMin: 24 * 60 };

  const dayKeys = $derived(days.map(dayKey));
  const visible = $derived(events.filter((ev) => dayKeys.includes(ev.day)));
  const hours = gutterHours(window);
  const bodyHeight = ((window.endMin - window.startMin) / 60) * HOUR_PX;
  const todayKey = $derived(dayKey(now));
  const nowPct = $derived(nowOffsetPct(minutesOfDay(now), window));

  // Scroll 08:00 to the top of the visible pane on mount (and when the
  // visible day set changes, which re-creates the anchor element).
  let morningAnchor = $state<HTMLElement | null>(null);
  $effect(() => {
    morningAnchor?.scrollIntoView({ block: 'start' });
  });

  function slotClick(event: MouseEvent, day: Date): void {
    if (!onCreateSlot) return;
    // Only clicks on the column's own empty surface — an EventCard (or any
    // other child control) handles its own click.
    const target = event.target as HTMLElement;
    const column = event.currentTarget as HTMLElement;
    if (target !== column && target.getAttribute('aria-hidden') !== 'true') return;
    const rect = column.getBoundingClientRect();
    const ratio = (event.clientY - rect.top) / rect.height;
    const raw = window.startMin + ratio * (window.endMin - window.startMin);
    const minutes = Math.max(0, Math.min(23 * 60 + 30, Math.floor(raw / 30) * 30));
    onCreateSlot(day, minutes);
  }

  function eventsFor(key: string): CalendarEvent[] {
    return visible.filter((ev) => ev.day === key).sort((a, b) => a.startMin - b.startMin);
  }

  const allDayVisible = $derived(allDay.filter((entry) => dayKeys.includes(entry.day)));

  function allDayFor(key: string): AllDayEntry[] {
    return allDayVisible.filter((entry) => entry.day === key);
  }

  function linePct(hour: number): number {
    return ((hour * 60 - window.startMin) / (window.endMin - window.startMin)) * 100;
  }

  const ALL_DAY_CHIP: Record<AllDayEntry['kind'], string> = {
    booked: 'border-l-2 border-act bg-act-tint text-ink-heading',
    block: 'bg-paper-track text-ink-secondary',
    hold: 'border border-dashed border-suggest-dash text-suggest-ink',
    routine: 'border border-act bg-paper-card text-ink-heading'
  };
</script>

<div
  class="grid"
  style={`grid-template-columns: 52px repeat(${days.length}, minmax(0, 1fr));`}
  role="grid"
  aria-label="Calendar"
>
  <!-- header row -->
  <div class="border-paper-hairline border-b" role="presentation"></div>
  {#each days as day (dayKey(day))}
    {@const parts = dayHeaderParts(day)}
    {@const isToday = dayKey(day) === todayKey}
    <div
      class={[
        'border-paper-hairline border-b border-l px-2.5 py-2 text-[12px]',
        isToday && 'bg-paper-pill'
      ]}
      role="columnheader"
    >
      <span class={isToday ? 'text-ink-heading font-semibold' : 'text-ink-secondary'}>
        {parts.weekday}
        <span class={['tabular-nums', isToday ? 'text-ink-heading' : 'text-ink-heading/80']}>{parts.day}</span>
      </span>
      {#if isToday}
        <span class="text-warn-ink text-[11px]">· today</span>
      {/if}
    </div>
  {/each}

  <!-- all-day lane (Spec F) — rendered only when the visible days carry any all-day chips -->
  {#if allDayVisible.length > 0}
    <div class="border-paper-hairline text-ink-meta border-b py-1.5 pr-2.5 text-right text-[10.5px]" role="presentation">
      all-day
    </div>
    {#each days as day (dayKey(day))}
      <div class="border-paper-hairline flex min-h-7 flex-col gap-0.5 border-b border-l p-1" role="gridcell">
        {#each allDayFor(dayKey(day)) as entry (entry.id)}
          <svelte:element
            this={onSelect ? 'button' : 'span'}
            {...onSelect ? { type: 'button', onclick: () => onSelect?.(entry.id) } : {}}
            class={[
              'truncate rounded-[5px] px-1.5 py-0.5 text-left text-[10.5px] leading-snug',
              ALL_DAY_CHIP[entry.kind],
              entry.cancelled && 'line-through opacity-70'
            ]}
            title={entry.title}
          >
            {entry.title}
          </svelte:element>
        {/each}
      </div>
    {/each}
  {/if}

  <!-- hour gutter -->
  <div class="relative" style={`height:${bodyHeight}px`} role="presentation">
    <span
      bind:this={morningAnchor}
      class="pointer-events-none absolute inset-x-0"
      style={`top:${linePct(8)}%`}
      aria-hidden="true"
    ></span>
    {#each hours as hour (hour)}
      <span
        class="text-ink-meta absolute right-2.5 -translate-y-1/2 text-[10.5px] tabular-nums"
        style={`top:${linePct(hour)}%`}
      >
        {timeLabel(hour * 60)}
      </span>
    {/each}
  </div>

  <!-- day columns -->
  {#each days as day (dayKey(day))}
    {@const key = dayKey(day)}
    <!-- Pointer-only slot affordance — the header's "New event" button is
         the keyboard path to the same editor, so no key handler here. -->
    <!-- svelte-ignore a11y_click_events_have_key_events, a11y_no_noninteractive_element_interactions, a11y_interactive_supports_focus -->
    <div
      class="border-paper-hairline relative border-b border-l"
      style={`height:${bodyHeight}px`}
      role="gridcell"
      onclick={(e) => slotClick(e, day)}
    >
      {#each hours as hour (hour)}
        {#if hour * 60 > window.startMin}
          <div
            class="border-paper-hairline absolute inset-x-0 border-t"
            style={`top:${linePct(hour)}%`}
            aria-hidden="true"
          ></div>
        {/if}
      {/each}

      {#each eventsFor(key) as event (event.id)}
        {@const box = eventBox(event, window)}
        <div class="absolute right-1.5 left-1" style={`top:${box.topPct}%;height:${box.heightPct}%`}>
          <EventCard {event} past={isPastEvent(event, now)} onSelect={onSelect ? (ev) => onSelect?.(ev.id) : undefined} />
        </div>
      {/each}

      {#if key === todayKey && nowPct !== null}
        <div class="pointer-events-none absolute inset-x-0 z-10" style={`top:${nowPct}%`} aria-hidden="true">
          <div class="border-warn-ink relative border-t-[1.5px]">
            <span class="bg-warn-ink absolute -top-[3.5px] -left-[2.5px] size-1.5 rounded-full"></span>
          </div>
        </div>
      {/if}
    </div>
  {/each}
</div>
