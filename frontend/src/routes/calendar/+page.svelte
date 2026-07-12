<script lang="ts">
  // Calendar route — view only this phase (frontend, placeholder data).
  // The CalDAV/ICS sync engine and its store land in the dedicated
  // Calendar phase and replace `placeholder-week.ts` with the same
  // `CalendarEvent` shape; see
  // docs/superpowers/specs/2026-07-12-calendar-view-frontend-design.md.
  //
  // Read-only by design, not just by phase: booking, moving or cancelling
  // always goes through the approval queue, never through direct
  // manipulation on the grid.
  import { AppFrame, Rail, RailCard, SegmentedControl } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import WeekGrid from '$lib/components/calendar/WeekGrid.svelte';
  import MonthGrid from '$lib/components/calendar/MonthGrid.svelte';
  import { placeholderAnchor, placeholderWeek } from '$lib/components/calendar/placeholder-week';
  import {
    addDays,
    addMonths,
    dateFromKey,
    isPastEvent,
    monthLabel,
    rangeLabel,
    timeLabel,
    workWeekFor,
    type CalendarEvent
  } from '$lib/components/calendar/calendar-shapes';

  // Seeded once for the week the app was opened in (upcoming week on
  // weekends — see `placeholderAnchor`); paging away shows honest empty
  // weeks rather than repeating demo data. The initial visible week uses
  // the same anchor so the seed is on screen.
  const events = placeholderWeek(new Date());

  let anchor = $state(addDays(placeholderAnchor(new Date()), 0)); // local midnight
  let view = $state<'day' | 'week' | 'month'>('week');
  let now = $state(new Date());

  // Keep the now-line and past-event dimming honest while the app stays
  // open; a minute of drift is the finest granularity the grid renders.
  $effect(() => {
    const timer = setInterval(() => (now = new Date()), 60_000);
    return () => clearInterval(timer);
  });

  const days = $derived(view === 'week' ? workWeekFor(anchor) : [anchor]);
  const title = $derived(view === 'month' ? monthLabel(anchor) : rangeLabel(days));

  function step(direction: 1 | -1): void {
    if (view === 'month') {
      anchor = addMonths(anchor, direction);
      return;
    }
    anchor = addDays(anchor, (view === 'week' ? 7 : 1) * direction);
  }

  // Month cells click through to that day's time grid.
  function openDay(day: Date): void {
    anchor = day;
    view = 'day';
  }

  // -- rail derivations (same placeholder events the grid renders) ----------

  const openHolds = $derived(events.filter((ev) => ev.kind === 'hold' && !isPastEvent(ev, now)));

  const nextSession = $derived.by((): CalendarEvent | null => {
    const upcoming = events
      .filter((ev) => ev.kind === 'booked' && !isPastEvent(ev, now))
      .sort((a, b) => (a.day === b.day ? a.startMin - b.startMin : a.day < b.day ? -1 : 1));
    return upcoming[0] ?? null;
  });

  const WEEKDAY_LONG = new Intl.DateTimeFormat('en-US', { weekday: 'long' });
</script>

<AppFrame mainVariant="column">
  {#snippet main()}
    <div class="flex min-h-0 flex-1 flex-col">
      <header class="flex flex-wrap items-center gap-x-4 gap-y-2 px-7 pt-6 pb-4">
        <h1 class="font-display text-ink-heading text-[22px] leading-tight font-medium">
          {title}
        </h1>

        <div class="flex items-center gap-1">
          <Button type="button" variant="outline" size="icon-sm" aria-label="Previous" onclick={() => step(-1)}>
            <ChevronLeft strokeWidth={1.5} />
          </Button>
          <Button type="button" variant="outline" size="icon-sm" aria-label="Next" onclick={() => step(1)}>
            <ChevronRight strokeWidth={1.5} />
          </Button>
        </div>

        <div class="text-ink-secondary flex items-center gap-4 text-[12px]">
          <span class="flex items-center gap-1.5">
            <span class="bg-act size-2.5 rounded-[3px]" aria-hidden="true"></span>
            Booked
          </span>
          <span class="flex items-center gap-1.5">
            <span class="bg-paper-button-border size-2.5 rounded-[3px]" aria-hidden="true"></span>
            Blocks
          </span>
          <span class="flex items-center gap-1.5">
            <span
              class="border-suggest-dash size-2.5 rounded-[3px] border-[1.5px] border-dashed"
              aria-hidden="true"
            ></span>
            Holds
          </span>
        </div>

        <span class="min-w-2 flex-1" aria-hidden="true"></span>

        <SegmentedControl
          label="Calendar view"
          value={view}
          options={[
            { value: 'day', label: 'Day' },
            { value: 'week', label: 'Week' },
            { value: 'month', label: 'Month' }
          ]}
          onChange={(v) => (view = v as 'day' | 'week' | 'month')}
        />
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-7 pb-7">
        {#if view === 'month'}
          <MonthGrid {anchor} {events} {now} onSelectDay={openDay} />
        {:else}
          <WeekGrid {days} {events} {now} />
        {/if}
      </div>
    </div>
  {/snippet}

  {#snippet rail()}
    <Rail title="Around your week">
      {#if openHolds.length > 0}
        <RailCard
          tone="suggest"
          overline={`${openHolds.length} ${openHolds.length === 1 ? 'hold' : 'holds'} · offered in draft`}
        >
          <p class="text-ink-body text-[12.5px] leading-relaxed">
            Held while the drafted reply waits for your approval. When a time is picked it becomes
            a booking and the other hold is released.
          </p>
        </RailCard>
      {/if}

      {#if nextSession}
        <RailCard
          tone="act"
          overline={`${WEEKDAY_LONG.format(dateFromKey(nextSession.day))}, ${timeLabel(nextSession.startMin)}`}
        >
          <p class="text-ink-heading text-[13px] font-semibold">{nextSession.title}</p>
          {#if nextSession.detail}
            <p class="text-ink-subtitle text-[12px]">{nextSession.detail}</p>
          {/if}
        </RailCard>
      {/if}

      <p class="text-ink-meta mt-auto pb-1 text-[11.5px] leading-relaxed">
        Booking, moving or cancelling always goes through you.
      </p>
    </Rail>
  {/snippet}
</AppFrame>
