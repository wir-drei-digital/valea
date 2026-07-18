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
  import { AppFrame, Rail, RailCard, SegmentedControl } from '$lib/components/shell';
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
    localParts,
    monthGridFor,
    monthLabel,
    occurrenceKey,
    occurrenceToGridEvents,
    rangeLabel,
    timeLabel,
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

  // -- rail derivations -------------------------------------------------------

  /** Deterministic legend color per source slug (stable across sessions — pure string hash). */
  function sourceHue(slug: string): number {
    let hash = 0;
    for (let i = 0; i < slug.length; i++) hash = (hash * 31 + slug.charCodeAt(i)) >>> 0;
    return hash % 360;
  }

  const legendSources = $derived.by((): string[] => {
    const slugs = new Set(calendarStore.sources.map((s) => s.source));
    if (calendarStore.valeaEventCount > 0 || calendarStore.events.some((row) => row.source === 'valea')) {
      slugs.add('valea');
    }
    return [...slugs].sort();
  });

  const upcoming = $derived.by((): { row: CalendarOccurrence; label: string }[] => {
    const today = dayKey(now);
    const nowMs = now.getTime();
    return calendarStore.events
      .filter((row) => (row.all_day ? row.end > today : Date.parse(row.end + '') > nowMs))
      .slice(0, 5)
      .map((row) => ({
        row,
        label: row.all_day
          ? `${row.start} · all day`
          : `${localParts(row.start, zone).day} ${timeLabel(localParts(row.start, zone).minutes)}`
      }));
  });

  const unsupportedTotal = $derived(calendarStore.sources.reduce((sum, s) => sum + s.unsupportedSeries, 0));
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

  {#snippet rail()}
    <Rail title="Sources">
      {#if calendarStore.configInvalid}
        <RailCard tone="suggest" overline="config invalid">
          <p class="text-ink-body text-[12.5px] leading-relaxed">{calendarStore.configInvalid}</p>
        </RailCard>
      {/if}

      {#if legendSources.length > 0}
        <ul class="flex flex-col gap-1.5">
          {#each legendSources as slug (slug)}
            {@const status = calendarStore.sources.find((s) => s.source === slug)}
            <li class="text-ink-body flex items-center gap-2 text-[12.5px]">
              <span
                class="size-2.5 rounded-full"
                style={`background: hsl(${sourceHue(slug)} 45% 55%)`}
                aria-hidden="true"
              ></span>
              {slug === 'valea' ? 'Valea calendar' : slug}
              {#if status && status.unsupportedSeries > 0}
                <span class="text-warn-ink text-[11px]">· {status.unsupportedSeries} series unsupported</span>
              {/if}
              {#if status && status.state === 'degraded'}
                <span class="text-warn-ink text-[11px]">· degraded</span>
              {/if}
            </li>
          {/each}
        </ul>
      {:else}
        <p class="text-ink-secondary text-[12.5px] leading-relaxed">
          No calendar sources yet — add an ICS feed under Sources, or let an agent create events in the Valea
          calendar.
        </p>
      {/if}

      {#if unsupportedTotal > 0}
        <p class="text-ink-meta text-[11.5px] leading-relaxed">
          Unsupported recurring series are never guessed at — they are absent from the grid and counted here instead.
        </p>
      {/if}

      {#if upcoming.length > 0}
        <RailCard tone="act" overline="Upcoming">
          <ul class="flex flex-col gap-1">
          {#each upcoming as item (occurrenceKey(item.row))}
            <li class="text-[12px]">
              <span class="text-ink-heading font-semibold">{item.row.summary}</span>
              <span class="text-ink-subtitle tabular-nums"> · {item.label}</span>
            </li>
          {/each}
          </ul>
        </RailCard>
      {/if}

      <p class="text-ink-meta mt-auto pb-1 text-[11.5px] leading-relaxed">
        External feeds are read-only mirrors. Valea-calendar events are plain files agents edit through the normal
        permission gate.
      </p>
    </Rail>
  {/snippet}
</AppFrame>
