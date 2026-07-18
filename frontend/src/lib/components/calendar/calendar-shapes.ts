/**
 * Pure, unit-testable types + math for the `/calendar` route — same "no
 * component render harness; extract the logic instead" convention as
 * `components/mail/mail-shapes.ts`.
 *
 * The grid layer stays backend-agnostic: the view renders whatever
 * `CalendarEvent[]` it is handed. `occurrenceToGridEvents` below is the ONE
 * adapter from the backend's `list_calendar_events` wire rows
 * (`CalendarOccurrence` — Spec F's pinned snake_case shape) into that grid
 * contract; `stores/calendar.svelte.ts` owns fetching the rows.
 *
 * No `Date.now()` in here — callers pass `now`/`today`/`hostZone` in, so
 * every helper is deterministic under test.
 */

// -- data contract (see docs/superpowers/specs/2026-07-12-calendar-view-…) --

/** §9 event vocabulary: solid = real, dashed = the assistant's hand. */
export type CalendarEventKind = 'booked' | 'block' | 'hold' | 'routine';

export type CalendarEvent = {
  id: string;
  title: string;
  /** Local calendar day, `YYYY-MM-DD` (see `dayKey`). */
  day: string;
  /** Minutes from local midnight. */
  startMin: number;
  endMin: number;
  kind: CalendarEventKind;
  /** Optional quiet second line: "Zoom · 75 min", "offered in draft", … */
  detail?: string;
  /** Cancelled valea events render struck-through (external cancellations never reach the wire). */
  cancelled?: boolean;
};

// -- days ---------------------------------------------------------------------

/** Local-timezone `YYYY-MM-DD` for a Date (NOT toISOString — that's UTC and shifts the day near midnight). */
export function dayKey(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, '0');
  const d = String(date.getDate()).padStart(2, '0');
  return `${y}-${m}-${d}`;
}

/** New Date `n` days after `date`, at local midnight. */
export function addDays(date: Date, n: number): Date {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate() + n);
}

/** Local-midnight Date for a `dayKey` string — inverse of `dayKey`. */
export function dateFromKey(key: string): Date {
  const [y, m, d] = key.split('-').map(Number);
  return new Date(y, m - 1, d);
}

/**
 * The Mon–Fri work week containing `anchor` (ISO convention: weeks start
 * Monday, so a Saturday/Sunday anchor maps to the week just ended). Five
 * local-midnight Dates, per the V1 screen's five columns.
 */
export function workWeekFor(anchor: Date): Date[] {
  const mondayOffset = (anchor.getDay() + 6) % 7; // Mon=0 … Sun=6
  const monday = addDays(anchor, -mondayOffset);
  return [0, 1, 2, 3, 4].map((i) => addDays(monday, i));
}

/** New Date `n` months after `date`, day-of-month clamped to the target month's length (Jan 31 + 1 → Feb 28/29). */
export function addMonths(date: Date, n: number): Date {
  const target = new Date(date.getFullYear(), date.getMonth() + n, 1);
  const daysInTarget = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate();
  return new Date(target.getFullYear(), target.getMonth(), Math.min(date.getDate(), daysInTarget));
}

/**
 * The full Monday-start week rows covering `anchor`'s month — leading and
 * trailing out-month days included so every row has seven cells. 4–6 rows
 * depending on the month's shape.
 */
export function monthGridFor(anchor: Date): Date[][] {
  const first = new Date(anchor.getFullYear(), anchor.getMonth(), 1);
  const last = new Date(anchor.getFullYear(), anchor.getMonth() + 1, 0);
  const start = addDays(first, -((first.getDay() + 6) % 7));
  const weeks: Date[][] = [];
  for (let cursor = start; cursor <= last; cursor = addDays(cursor, 7)) {
    weeks.push([0, 1, 2, 3, 4, 5, 6].map((i) => addDays(cursor, i)));
  }
  return weeks;
}

const MONTH_LONG = new Intl.DateTimeFormat('en-US', { month: 'long' });
const MONTH_YEAR = new Intl.DateTimeFormat('en-US', { month: 'long', year: 'numeric' });
const WEEKDAY_SHORT = new Intl.DateTimeFormat('en-US', { weekday: 'short' });
const WEEKDAY_LONG = new Intl.DateTimeFormat('en-US', { weekday: 'long' });

/** Month-view header title: "July 2026". */
export function monthLabel(date: Date): string {
  return MONTH_YEAR.format(date);
}

/**
 * Header title for the visible range: "July 7 – 11" within one month,
 * "June 30 – July 4" across months, "Wednesday, July 9" for a single day.
 */
export function rangeLabel(days: Date[]): string {
  if (days.length === 0) return '';
  const first = days[0];
  const last = days[days.length - 1];
  if (days.length === 1) {
    return `${WEEKDAY_LONG.format(first)}, ${MONTH_LONG.format(first)} ${first.getDate()}`;
  }
  if (first.getMonth() === last.getMonth()) {
    return `${MONTH_LONG.format(first)} ${first.getDate()} – ${last.getDate()}`;
  }
  return `${MONTH_LONG.format(first)} ${first.getDate()} – ${MONTH_LONG.format(last)} ${last.getDate()}`;
}

/** Column header pieces: `{ weekday: "Mon", day: 7 }`. */
export function dayHeaderParts(date: Date): { weekday: string; day: number } {
  return { weekday: WEEKDAY_SHORT.format(date), day: date.getDate() };
}

// -- hour window ---------------------------------------------------------------

export type HourWindow = { startMin: number; endMin: number };

/** The V1 screen's default band; the window never shrinks below it. */
export const BASE_WINDOW: HourWindow = { startMin: 9 * 60, endMin: 17 * 60 };

/**
 * Visible hour band: the base band stretched to cover every event, then
 * floored/ceiled to whole hours and clamped to the local day.
 */
export function hourWindow(events: CalendarEvent[], base: HourWindow = BASE_WINDOW): HourWindow {
  let start = base.startMin;
  let end = base.endMin;
  for (const ev of events) {
    if (ev.startMin < start) start = ev.startMin;
    if (ev.endMin > end) end = ev.endMin;
  }
  return {
    startMin: Math.max(0, Math.floor(start / 60) * 60),
    endMin: Math.min(24 * 60, Math.ceil(end / 60) * 60)
  };
}

/** Whole hours at which grid lines + gutter labels sit: window start up to (not including) the bottom edge. */
export function gutterHours(window: HourWindow): number[] {
  const first = Math.ceil(window.startMin / 60);
  const last = Math.ceil(window.endMin / 60) - 1;
  const hours: number[] = [];
  for (let h = first; h <= last; h++) hours.push(h);
  return hours;
}

// -- positioning ---------------------------------------------------------------

/** Percent offsets of an event inside the window (clamped; zero-height events get a 1-minute floor so they stay visible). */
export function eventBox(
  ev: Pick<CalendarEvent, 'startMin' | 'endMin'>,
  window: HourWindow
): { topPct: number; heightPct: number } {
  const total = window.endMin - window.startMin;
  const start = Math.max(ev.startMin, window.startMin);
  const end = Math.min(Math.max(ev.endMin, start + 1), window.endMin);
  return {
    topPct: ((start - window.startMin) / total) * 100,
    heightPct: ((end - start) / total) * 100
  };
}

/** Minutes from local midnight for a Date. */
export function minutesOfDay(date: Date): number {
  return date.getHours() * 60 + date.getMinutes();
}

/** Percent offset of "now" inside the window, or `null` when now is outside it. */
export function nowOffsetPct(nowMin: number, window: HourWindow): number | null {
  if (nowMin < window.startMin || nowMin > window.endMin) return null;
  return ((nowMin - window.startMin) / (window.endMin - window.startMin)) * 100;
}

/** §9 "past events at 0.55 opacity": the event's day is over, or it ended earlier today. */
export function isPastEvent(ev: CalendarEvent, now: Date): boolean {
  const today = dayKey(now);
  if (ev.day < today) return true;
  if (ev.day > today) return false;
  return ev.endMin <= minutesOfDay(now);
}

// -- labels ---------------------------------------------------------------------

/** 24h clock label, no leading zero on the hour: "9:00", "16:30" — matches the V1 screen. */
export function timeLabel(min: number): string {
  const h = Math.floor(min / 60);
  const m = min % 60;
  return `${h}:${String(m).padStart(2, '0')}`;
}

/** "11:00 – 12:15" for an event's second line. */
export function timeRangeLabel(startMin: number, endMin: number): string {
  return `${timeLabel(startMin)} – ${timeLabel(endMin)}`;
}

// -- the RPC → grid adapter (Spec F §UI) ---------------------------------------

/**
 * One `list_calendar_events` row, EXACTLY as the backend serializes it —
 * string keys, snake_case, no camelCase translation (the `events` field is
 * an unconstrained array; see `Valea.Api.Calendar`'s moduledoc). Tagged by
 * `all_day`: timed rows carry UTC `YYYY-MM-DDTHH:MM:SSZ` instants, all-day
 * rows carry plain `YYYY-MM-DD` dates with `end` EXCLUSIVE.
 */
export type CalendarOccurrence = {
  source: string; // slug, or "valea"
  all_day: boolean;
  start: string;
  end: string;
  summary: string;
  location: string | null;
  status: 'confirmed' | 'tentative' | 'cancelled' | string;
  description: string | null;
  /** External rows: workspace-relative derived-view path. `null` on valea rows. */
  view_path: string | null;
  /** Valea rows: workspace-relative event-file path. `null` on external rows. */
  path: string | null;
};

/** One chip in the grids' all-day lane — plain dates, no minutes. */
export type AllDayEntry = {
  id: string;
  /** Local calendar day (`YYYY-MM-DD`) this chip renders on. */
  day: string;
  title: string;
  kind: CalendarEventKind;
  cancelled: boolean;
};

/**
 * Stable identity for one occurrence row — the grids key segments on
 * `id` (`<occurrenceKey>@<day>`), and the route resolves a selected id back
 * to its row through this same key.
 */
export function occurrenceKey(row: CalendarOccurrence): string {
  return `${row.source}|${row.all_day ? 'd' : 't'}|${row.start}|${row.end}|${row.summary}`;
}

/** Spec F kind mapping: external+confirmed → booked, external+tentative → hold, valea → block. */
export function occurrenceKind(row: CalendarOccurrence): CalendarEventKind {
  if (row.source === 'valea') return 'block';
  return row.status === 'tentative' ? 'hold' : 'booked';
}

/** Local `{day, minutes}` of a UTC instant in `zone` (Intl-based — no date-fns dependency). */
export function localParts(isoUtc: string, zone: string): { day: string; minutes: number } {
  const fmt = new Intl.DateTimeFormat('en-CA', {
    timeZone: zone,
    year: 'numeric',
    month: '2-digit',
    day: '2-digit',
    hour: '2-digit',
    minute: '2-digit',
    hourCycle: 'h23'
  });
  const parts: Record<string, string> = {};
  for (const p of fmt.formatToParts(new Date(isoUtc))) parts[p.type] = p.value;
  return {
    day: `${parts.year}-${parts.month}-${parts.day}`,
    minutes: Number(parts.hour) * 60 + Number(parts.minute)
  };
}

/** Calendar-day arithmetic on `YYYY-MM-DD` keys (zone-agnostic — pure Y/M/D). */
function nextDayKey(key: string): string {
  return dayKey(addDays(dateFromKey(key), 1));
}

/**
 * THE adapter (Spec F §UI, pinned contract): one wire row → grid pieces.
 *
 * TIMED rows: UTC instants converted to `hostZone` wall time, split into one
 * `CalendarEvent` segment per local day (first day starts at the local start
 * minute, last day ends at the local end minute, full 0–1440 in between; an
 * end at exactly local midnight closes the previous day's segment rather
 * than opening an empty one). ALL-DAY rows: the plain dates are used
 * DIRECTLY — no zone conversion — and `[start, end)` (end EXCLUSIVE) splits
 * into one `AllDayEntry` per day for the grids' all-day lane.
 *
 * CANCELLED external occurrences never reach the wire (removed at
 * expansion); cancelled VALEA events do arrive and render struck-through,
 * so `cancelled` rides both shapes (segments via `detail` styling in the
 * card, all-day chips via the flag).
 */
export function occurrenceToGridEvents(
  row: CalendarOccurrence,
  hostZone: string
): { segments: CalendarEvent[]; allDay: AllDayEntry[] } {
  const key = occurrenceKey(row);
  const kind = occurrenceKind(row);
  const cancelled = row.status === 'cancelled';

  if (row.all_day) {
    const allDay: AllDayEntry[] = [];
    for (let day = row.start; day < row.end; day = nextDayKey(day)) {
      allDay.push({ id: `${key}@${day}`, day, title: row.summary, kind, cancelled });
    }
    return { segments: [], allDay };
  }

  const start = localParts(row.start, hostZone);
  const end = localParts(row.end, hostZone);
  const segments: CalendarEvent[] = [];
  for (let day = start.day; day <= end.day; day = nextDayKey(day)) {
    const startMin = day === start.day ? start.minutes : 0;
    const endMin = day === end.day ? end.minutes : 24 * 60;
    // An instant ending at exactly local midnight belongs wholly to the
    // previous day — skip the empty segment it would open (but keep a
    // genuinely zero-length single-day event visible via eventBox's floor).
    if (endMin === 0 && day === end.day && day !== start.day) break;
    segments.push({
      id: `${key}@${day}`,
      title: row.summary,
      day,
      startMin,
      endMin,
      kind,
      detail: row.location ?? undefined,
      cancelled
    });
  }
  return { segments, allDay: [] };
}
