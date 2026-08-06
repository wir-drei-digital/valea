/**
 * The Today header's words (spec §Header). Pure and locale-injectable so the
 * hour/date/summary rules are testable; the route passes the live clock.
 * No user name exists in the product — the greeting stays impersonal.
 */
export function greetingForHour(hour: number): string {
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/** "Thursday, August 6" — the §11 overline date. CSS uppercases; this stays plain text. */
export function dateOverline(date: Date, locale?: string): string {
  return date.toLocaleDateString(locale, { weekday: 'long', month: 'long', day: 'numeric' });
}

export type SummarySegment = { text: string; tone: 'meta' | 'warn' };

/**
 * The one-line day summary. Parts drop at zero so a quiet day reads quietly;
 * the renderer joins with " · " and the whole line hides when nothing is left.
 * `todayCount` already includes overdue (they are today's work too).
 */
export function daySummarySegments(input: {
  todayCount: number;
  overdueCount: number;
  attentionCount: number;
  nextEventTime: string | null;
}): SummarySegment[] {
  const segments: SummarySegment[] = [];
  if (input.todayCount > 0) {
    segments.push({ text: `${input.todayCount} ${input.todayCount === 1 ? 'task' : 'tasks'} for today`, tone: 'meta' });
  }
  if (input.overdueCount > 0) segments.push({ text: `${input.overdueCount} overdue`, tone: 'warn' });
  if (input.attentionCount > 0) {
    segments.push({
      text:
        input.attentionCount === 1
          ? '1 thing needs your attention'
          : `${input.attentionCount} things need your attention`,
      tone: 'meta'
    });
  }
  if (input.nextEventTime !== null) segments.push({ text: `next event ${input.nextEventTime}`, tone: 'meta' });
  return segments;
}
