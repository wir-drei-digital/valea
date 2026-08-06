<script lang="ts">
  // Today's agenda (redesign spec §Agenda): the day's timed events, read
  // through the SAME query path the `/calendar` route uses — the
  // `list_calendar_events` RPC, normalized by `normalizeOccurrence` and adapted
  // by `occurrenceToGridEvents`. Nothing about the calendar's shape is
  // re-derived here; this section is a different rendering of the same rows.
  //
  // WHETHER it appears is the cockpit's call, not this component's: `enabled`
  // is `today.calendar !== null`, the payload's "the calendar subsystem has
  // something to say" signal (`Valea.Cockpit.calendar_summary/0` answers `nil`
  // for a workspace with no calendar at all). A workspace WITH a calendar and
  // an empty day gets the quiet line — "nothing today" is an answer; "no
  // calendar" is not a question.
  //
  // The fetch is its own RPC rather than a read of `calendarStore`: that store
  // holds the CALENDAR ROUTE's visible range, and loading a single day into it
  // from here would silently narrow the week the other page is showing.
  import { untrack } from 'svelte';
  import { api } from '$lib/api/client';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Skeleton } from '$lib/components/ui/skeleton/index.js';
  import { normalizeOccurrence } from '$lib/stores/calendar.svelte';
  import {
    addDays,
    dateFromKey,
    dayKey,
    occurrenceToGridEvents,
    type CalendarEvent
  } from '$lib/components/calendar/calendar-shapes';
  import { agendaRows, type AgendaRow } from '$lib/today/today-view';

  let {
    enabled,
    todayIso,
    zone,
    onEvents
  }: {
    /** `today.calendar !== null` — see the note above; `false` renders nothing and fetches nothing. */
    enabled: boolean;
    /** Local calendar date (`YYYY-MM-DD`); the route owns "what day is it" and re-reads it at midnight. */
    todayIso: string;
    /** IANA zone the range is interpreted in — `Intl.DateTimeFormat().resolvedOptions().timeZone`. */
    zone: string;
    /**
     * The day's timed segments, handed up for the header's `next event HH:MM`.
     * Called on a SUCCESSFUL load only: a route that also owns the whole-page
     * empty state must be able to tell "no events" from "not answered yet", and
     * an error reported as an empty day would put the welcome card on screen
     * beside the failure line.
     */
    onEvents: (events: CalendarEvent[]) => void;
  } = $props();

  let rows = $state<AgendaRow[]>([]);
  let loading = $state(true);
  let failed = $state(false);

  /**
   * Identifies the newest request. A PLAIN field, not `$state`: `load` writes it
   * synchronously and a slow earlier reply must not clobber a newer day's rows
   * (`CalendarStore`'s `#fetchToken` note, verbatim reasoning).
   */
  let fetchToken: object = {};

  async function load(day: string): Promise<void> {
    const mine = {};
    fetchToken = mine;
    loading = true;
    failed = false;

    const result = await api.listCalendarEvents(day, dayKey(addDays(dateFromKey(day), 1)), zone);
    if (fetchToken !== mine) return;
    loading = false;

    if (!result.ok) {
      failed = true;
      return;
    }

    const data = result.data as { events?: unknown };
    const raw = Array.isArray(data.events) ? (data.events as Record<string, unknown>[]) : [];
    // The range is half-open `[day, day+1)` (`Valea.Api.Calendar.events_in_range/4`),
    // and it returns every occurrence OVERLAPPING it — so a meeting that began
    // yesterday and runs into this morning arrives whole and splits into a
    // segment per local day. Only today's segment belongs on today's agenda.
    const segments = raw
      .flatMap((row) => {
        const occurrence = normalizeOccurrence(row);
        return occurrence === null ? [] : occurrenceToGridEvents(occurrence, zone).segments;
      })
      .filter((segment) => segment.day === day);

    rows = agendaRows(segments);
    onEvents(segments);
  }

  // Mount, and again whenever the day rolls over. `untrack` for the reason the
  // calendar route states at its own load effect: the call writes state
  // synchronously, and a tracked call site self-retriggers into an RPC loop.
  $effect(() => {
    if (!enabled) return;
    const day = todayIso;
    untrack(() => void load(day));
  });
</script>

{#if enabled}
  <section>
    <h2 class="text-overline mb-2">Agenda</h2>

    {#if loading}
      <div class="flex flex-col gap-2" aria-hidden="true">
        <Skeleton class="h-4 w-2/3" />
        <Skeleton class="h-4 w-1/2" />
      </div>
    {:else if failed}
      <!-- Scoped to this section, per the leniency contract: the rest of the
           day still renders, and the retry re-asks only this question. -->
      <div class="flex flex-wrap items-center gap-3">
        <p class="text-ink-body text-[13px]">Couldn't read today's events.</p>
        <Button variant="outline" size="sm" onclick={() => void load(todayIso)}>Retry</Button>
      </div>
    {:else if rows.length === 0}
      <p class="text-ink-meta text-[13px]">No events today.</p>
    {:else}
      <ul class="flex flex-col">
        {#each rows as row, i (`${row.time}/${row.title}/${i}`)}
          <li class="border-paper-hairline flex items-baseline gap-2 border-b py-1.5 last:border-b-0">
            <span class="text-ink-secondary w-10 shrink-0 text-[13px] tabular-nums">{row.time}</span>
            <!-- A cancelled event keeps its line, struck through, the way the
                 week and month grids draw it: the hour it freed is the point,
                 and two views of one calendar must not disagree. -->
            <span
              class={[
                'min-w-0 flex-1 truncate text-[13px]',
                row.cancelled ? 'text-ink-meta line-through' : 'text-ink-body'
              ]}>{row.title}</span
            >
            {#if row.duration}
              <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">{row.duration}</span>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </section>
{/if}
