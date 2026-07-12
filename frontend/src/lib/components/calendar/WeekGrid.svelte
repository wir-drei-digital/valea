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
    hourWindow,
    isPastEvent,
    minutesOfDay,
    nowOffsetPct,
    timeLabel,
    type CalendarEvent
  } from './calendar-shapes';
  import EventCard from './EventCard.svelte';

  let { days, events, now }: { days: Date[]; events: CalendarEvent[]; now: Date } = $props();

  // 64px per hour — dense enough for a 9–18 band without scrolling on a
  // laptop, roomy enough for a title + time line on a 45-minute event.
  const HOUR_PX = 64;

  const dayKeys = $derived(days.map(dayKey));
  const visible = $derived(events.filter((ev) => dayKeys.includes(ev.day)));
  const window = $derived(hourWindow(visible));
  const hours = $derived(gutterHours(window));
  const bodyHeight = $derived(((window.endMin - window.startMin) / 60) * HOUR_PX);
  const todayKey = $derived(dayKey(now));
  const nowPct = $derived(nowOffsetPct(minutesOfDay(now), window));

  function eventsFor(key: string): CalendarEvent[] {
    return visible.filter((ev) => ev.day === key).sort((a, b) => a.startMin - b.startMin);
  }

  function linePct(hour: number): number {
    return ((hour * 60 - window.startMin) / (window.endMin - window.startMin)) * 100;
  }
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

  <!-- hour gutter -->
  <div class="relative" style={`height:${bodyHeight}px`} role="presentation">
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
    <div class="border-paper-hairline relative border-b border-l" style={`height:${bodyHeight}px`} role="gridcell">
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
          <EventCard {event} past={isPastEvent(event, now)} />
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
