<script lang="ts">
  // Calendar route — real data (Spec F): external ICS mirrors + the
  // agent-writable Valea calendar, served by `list_calendar_events` through
  // `CalendarStore` and adapted into the grid contract by
  // `occurrenceToGridEvents`. External events are read-only (detail
  // popover); Valea events add edit/delete and the "New event" editor —
  // agents write the same files through the normal permission gate, so
  // everything on this grid is a plain file under `sources/calendar/`.
  import { onMount, untrack } from 'svelte';
  import { page } from '$app/state';
  import { AppFrame, SegmentedControl } from '$lib/components/shell';
  import { Button } from '$lib/components/ui/button/index.js';
  import ChevronLeft from '@lucide/svelte/icons/chevron-left';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import WeekGrid from '$lib/components/calendar/WeekGrid.svelte';
  import MonthGrid from '$lib/components/calendar/MonthGrid.svelte';
  import EventPopover from '$lib/components/calendar/EventPopover.svelte';
  import EventEditorPanel from '$lib/components/calendar/EventEditorPanel.svelte';
  import CalendarSetupPanel from '$lib/components/calendar/CalendarSetupPanel.svelte';
  import { calendarStore } from '$lib/stores/calendar.svelte';
  import {
    addDays,
    addMonths,
    dayKey,
    monthGridFor,
    monthLabel,
    occurrenceKey,
    occurrenceToGridEvents,
    rangeLabel,
    workWeekFor,
    type AllDayEntry,
    type CalendarEvent,
    type CalendarOccurrence
  } from '$lib/components/calendar/calendar-shapes';

  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  let anchor = $state(new Date(new Date().getFullYear(), new Date().getMonth(), new Date().getDate()));
  let view = $state<'day' | 'week' | 'month'>('week');
  let now = $state(new Date());
  // `/calendar?setup=1` deep-links straight into the Sources panel (the
  // mail route's `?setup=1` convention) — used by the /sources hub.
  let showSetup = $state(page.url.searchParams.get('setup') === '1');
  let selectedId: string | null = $state(null);
  let editor: { mode: 'create' } | { mode: 'edit'; occurrence: CalendarOccurrence } | null = $state(null);

  // Keep the now-line and past-event dimming honest while the app stays
  // open; a minute of drift is the finest granularity the grid renders.
  $effect(() => {
    const timer = setInterval(() => (now = new Date()), 60_000);
    return () => clearInterval(timer);
  });

  const days = $derived(view === 'week' ? workWeekFor(anchor) : [anchor]);
  const title = $derived(view === 'month' ? monthLabel(anchor) : rangeLabel(days));

  // Visible half-open range [from, to) — what `list_calendar_events` loads.
  const range = $derived.by((): { from: string; to: string } => {
    if (view === 'month') {
      const weeks = monthGridFor(anchor);
      const first = weeks[0][0];
      const last = weeks[weeks.length - 1][6];
      return { from: dayKey(first), to: dayKey(addDays(last, 1)) };
    }
    const first = days[0];
    const last = days[days.length - 1];
    return { from: dayKey(first), to: dayKey(addDays(last, 1)) };
  });

  // Track ONLY the route's visible range: `loadEvents` itself reads and
  // writes `calendarStore.range` ($state) synchronously, so calling it
  // tracked would make this effect self-retriggering — an infinite RPC
  // loop that starves the page (found in the 2026-07-19 browser test run).
  $effect(() => {
    const { from, to } = range;
    untrack(() => void calendarStore.loadEvents(from, to, zone));
  });

  onMount(() => {
    void calendarStore.refreshStatus();
  });

  // -- wire rows → grid pieces ----------------------------------------------

  const byKey = $derived(new Map(calendarStore.events.map((row) => [occurrenceKey(row), row])));

  const grid = $derived.by((): { segments: CalendarEvent[]; allDay: AllDayEntry[] } => {
    const segments: CalendarEvent[] = [];
    const allDay: AllDayEntry[] = [];
    for (const row of calendarStore.events) {
      const pieces = occurrenceToGridEvents(row, zone);
      segments.push(...pieces.segments);
      allDay.push(...pieces.allDay);
    }
    return { segments, allDay };
  });

  const selected = $derived.by((): CalendarOccurrence | null => {
    if (!selectedId) return null;
    const key = selectedId.slice(0, selectedId.lastIndexOf('@'));
    return byKey.get(key) ?? null;
  });

  function select(id: string): void {
    editor = null;
    selectedId = id;
  }

  function openDay(day: Date): void {
    anchor = day;
    view = 'day';
  }

  function step(direction: 1 | -1): void {
    if (view === 'month') {
      anchor = addMonths(anchor, direction);
      return;
    }
    anchor = addDays(anchor, (view === 'week' ? 7 : 1) * direction);
  }

</script>

<AppFrame mainVariant="column">
  {#snippet main()}
    <div class="relative flex min-h-0 flex-1 flex-col">
      <header class="flex flex-wrap items-center gap-x-4 gap-y-2 px-7 pt-6 pb-4">
        <h1 class="font-display text-ink-heading text-[22px] leading-tight font-medium">
          {showSetup ? 'Calendar sources' : title}
        </h1>

        {#if !showSetup}
          <div class="flex items-center gap-1">
            <Button type="button" variant="outline" size="icon-sm" aria-label="Previous" onclick={() => step(-1)}>
              <ChevronLeft strokeWidth={1.5} />
            </Button>
            <Button type="button" variant="outline" size="icon-sm" aria-label="Next" onclick={() => step(1)}>
              <ChevronRight strokeWidth={1.5} />
            </Button>
          </div>
        {/if}

        <span class="min-w-2 flex-1" aria-hidden="true"></span>

        {#if !showSetup}
          <Button type="button" variant="outline" size="sm" onclick={() => (editor = { mode: 'create' })}>
            New event
          </Button>
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
        {/if}
        <Button type="button" variant={showSetup ? 'default' : 'outline'} size="sm" onclick={() => (showSetup = !showSetup)}>
          {showSetup ? 'Back to calendar' : 'Sources'}
        </Button>
      </header>

      <div class="min-h-0 flex-1 overflow-y-auto px-7 pb-7">
        {#if showSetup}
          <CalendarSetupPanel />
        {:else if view === 'month'}
          <MonthGrid {anchor} events={grid.segments} allDay={grid.allDay} {now} onSelectDay={openDay} onSelect={select} />
        {:else}
          <WeekGrid {days} events={grid.segments} allDay={grid.allDay} {now} onSelect={select} />
        {/if}
      </div>

      {#if selected}
        <EventPopover
          occurrence={selected}
          {zone}
          onClose={() => (selectedId = null)}
          onEdit={(occurrence) => {
            selectedId = null;
            editor = { mode: 'edit', occurrence };
          }}
        />
      {/if}

      {#if editor}
        <EventEditorPanel
          initial={editor.mode === 'edit' ? editor.occurrence : null}
          onClose={() => (editor = null)}
          onSaved={() => (editor = null)}
        />
      {/if}
    </div>
  {/snippet}

</AppFrame>
