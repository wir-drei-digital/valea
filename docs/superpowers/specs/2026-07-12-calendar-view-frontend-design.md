# Calendar view — frontend (design phase, no wiring)

**Date:** 2026-07-12 · **Scope decision by user:** build the calendar *view*
against the Design System V1 calendar screen now; the CalDAV/ICS sync engine
and store wiring land in the dedicated Calendar phase (roadmap #5).

## Goal

Replace the `/calendar` stub with the cockpit week view from the V1 design
screen: work-week time grid, §9 event vocabulary, header with week
navigation + legend + Day/Week toggle, and the "Around your week" rail —
rendered from a typed placeholder data module the sync phase will replace.

## Non-goals (this phase)

- No backend, no store, no RPC, no `sources/calendar/` reading.
- No event creation, moving, or cancelling — the product never does direct
  manipulation anyway ("booking, moving or cancelling always goes through
  you"); read-only rendering.
- ~~No Month view.~~ *Superseded 2026-07-12: user requested Month.* The
  segmented control ships Day | Week | Month; Month renders Monday-start
  weeks with §9 vocabulary at chip density, and a day cell click opens that
  day's time grid.
- No overlap lanes. Placeholder data never overlaps; the real-data phase
  brings a lane algorithm if CalDAV events demand it.

## Decisions

- **Work week Mon–Fri**, per the design screen (5 columns). Weekend events
  are out of scope until real data exists.
- **Anchor = real today.** Placeholder events seed *relative to the current
  week* so the today highlight and now-line always demonstrate.
- **Hour window** derived from visible events, padded to whole hours, and
  never smaller than 09:00–17:00 (the design's band).
- **§9 vocabulary is the component contract:**
  - `booked` — solid `--act-tint` fill + 3px green left bar, radius 7.
  - `block` — solid neutral (`--paper-track`), no bar.
  - `hold` — dashed 1.5px `--suggest-dash` border on transparent paper,
    amber ink. Nothing dashed is ever committed.
  - `routine` — 1.5px solid green outline on card paper.
  - Past events at 0.55 opacity; the now-line is terracotta, today's column
    only.
- **Layout:** AppShell `mainVariant="column"` (the grid needs more than the
  660px prose column) + `rail` snippet (§10/§11: 290–340, panel paper,
  Newsreader title "Around your week").
- **Rail content** is derived from the same placeholder module (holds
  explainer card, next-session prep card) plus the standing caption
  "Booking, moving or cancelling always goes through you." The
  memory-update suggestion card from the screen belongs to the approval
  queue family and arrives with wiring.

## Units

| Unit | Purpose |
|---|---|
| `lib/components/calendar/calendar-shapes.ts` | Pure, unit-tested types + math: `CalendarEvent`, work-week derivation, range labels, hour window, event box %, now-line offset, past check. No DOM, no Date.now — callers pass `now`. |
| `lib/components/calendar/calendar-shapes.test.ts` | Vitest coverage for the above (Monday derivation incl. Sunday anchor, cross-month labels, box math, window clamping, now offset in/out). |
| `lib/components/calendar/placeholder-week.ts` | Seeded demo events relative to a passed `today`, typed as `CalendarEvent[]`. Deleted/replaced by the sync-engine store in the Calendar phase. |
| `lib/components/calendar/EventCard.svelte` | One event chip; kind → §9 styling; title 650 + time/detail meta lines. |
| `lib/components/calendar/WeekGrid.svelte` | Time gutter + day columns + hour hairlines + today header + now-line + absolutely positioned `EventCard`s. Presentational; takes `days`, `eventsByDay`, `window`, `now`. |
| `lib/components/calendar/MonthGrid.svelte` | Monday-start month cells (hairline gaps), mini §9 event chips with "+N more" overflow, out-month content dimming, today tint, day-click handoff to the route. |
| `routes/calendar/+page.svelte` | Header row (Newsreader range title, chevron prev/next, legend, Day/Week segmented), `WeekGrid`, rail. Owns view state (`anchor`, `view`). Replaces the `(stubs)/calendar` page. |

## Data contract (future wiring)

```ts
type CalendarEventKind = 'booked' | 'block' | 'hold' | 'routine';
type CalendarEvent = {
  id: string;
  title: string;
  day: string;        // local YYYY-MM-DD
  startMin: number;   // minutes from local midnight
  endMin: number;
  kind: CalendarEventKind;
  detail?: string;    // "Zoom · 75 min", "offered in draft", …
};
```

The sync engine's store must emit exactly this shape; everything under
`lib/components/calendar/` except `placeholder-week.ts` survives wiring
unchanged.

## Testing

- `calendar-shapes.test.ts` covers all exported helpers (see Units).
- Components verified visually in the dev preview against the V1 screen
  (`svelte-check` + existing suites must stay green).
