/**
 * PLACEHOLDER DATA — deleted/replaced in the Calendar sync phase (roadmap
 * #5), when a store over `sources/calendar/` files starts emitting the same
 * `CalendarEvent` shape (see calendar-shapes.ts and the 2026-07-12 spec).
 *
 * Events seed RELATIVE to the passed `today` so the today-column highlight,
 * past-event dimming, and the terracotta now-line always have something to
 * demonstrate, whatever week the app is opened in. Names reuse the seeded
 * workspace's own cast (Lea Brunner, Markus Weber, Julia Steiner — clients;
 * Priya Nair — the seeded inquiry whose drafted reply offers times).
 */
import { addDays, dayKey, workWeekFor, type CalendarEvent } from './calendar-shapes';

/**
 * Where the demo week lives relative to `today`: the current work week on
 * weekdays, the UPCOMING one on weekends (a Saturday/Sunday visitor would
 * otherwise open onto a fully past, fully dimmed grid). The route uses the
 * same anchor for its initial visible week so the seeded events are on
 * screen. Placeholder-only logic — real data has no such notion.
 */
export function placeholderAnchor(today: Date): Date {
  const day = today.getDay();
  if (day === 6) return addDays(today, 2); // Sat → next Monday
  if (day === 0) return addDays(today, 1); // Sun → next Monday
  return today;
}

export function placeholderWeek(today: Date): CalendarEvent[] {
  const [mon, tue, wed, thu, fri] = workWeekFor(placeholderAnchor(today)).map(dayKey);

  return [
    {
      id: 'ph-julia',
      title: 'Session · Julia Steiner',
      day: mon,
      startMin: 10 * 60,
      endMin: 11 * 60 + 15,
      kind: 'booked',
      detail: 'Zoom'
    },
    {
      id: 'ph-admin-block',
      title: 'Admin hour',
      day: tue,
      startMin: 9 * 60,
      endMin: 10 * 60,
      kind: 'block',
      detail: 'protected'
    },
    {
      id: 'ph-lea',
      title: 'Session · Lea Brunner',
      day: wed,
      startMin: 11 * 60,
      endMin: 12 * 60 + 15,
      kind: 'booked',
      detail: 'Zoom'
    },
    {
      id: 'ph-deepwork',
      title: 'Deep work — no meetings',
      day: wed,
      startMin: 15 * 60,
      endMin: 16 * 60,
      kind: 'block'
    },
    {
      id: 'ph-markus',
      title: 'Session · Markus Weber',
      day: wed,
      startMin: 16 * 60 + 30,
      endMin: 17 * 60 + 45,
      kind: 'booked',
      detail: 'in person'
    },
    {
      id: 'ph-julia-2',
      title: 'Session · Julia Steiner',
      day: thu,
      startMin: 9 * 60,
      endMin: 10 * 60 + 15,
      kind: 'booked',
      detail: '3 of 6'
    },
    {
      id: 'ph-hold-1',
      title: 'Hold · Priya — option 1',
      day: thu,
      startMin: 14 * 60,
      endMin: 15 * 60 + 15,
      kind: 'hold',
      detail: 'offered in draft'
    },
    {
      id: 'ph-hold-2',
      title: 'Hold · Priya — option 2',
      day: fri,
      startMin: 10 * 60,
      endMin: 11 * 60 + 15,
      kind: 'hold',
      detail: 'offered in draft'
    },
    {
      id: 'ph-review',
      title: 'Weekly admin review',
      day: fri,
      startMin: 16 * 60,
      endMin: 16 * 60 + 45,
      kind: 'routine',
      detail: 'with the assistant'
    }
  ];
}
