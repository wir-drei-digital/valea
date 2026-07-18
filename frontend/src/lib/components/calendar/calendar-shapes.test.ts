import { describe, expect, it } from 'vitest';
import {
  BASE_WINDOW,
  addDays,
  addMonths,
  dateFromKey,
  dayHeaderParts,
  dayKey,
  eventBox,
  gutterHours,
  hourWindow,
  isPastEvent,
  minutesOfDay,
  monthGridFor,
  monthLabel,
  nowOffsetPct,
  rangeLabel,
  timeLabel,
  timeRangeLabel,
  workWeekFor,
  type CalendarEvent
} from './calendar-shapes';

function ev(partial: Partial<CalendarEvent>): CalendarEvent {
  return {
    id: 'e1',
    title: 'Session',
    day: '2026-07-08',
    startMin: 11 * 60,
    endMin: 12 * 60 + 15,
    kind: 'booked',
    ...partial
  };
}

describe('dayKey', () => {
  it('renders local YYYY-MM-DD with padding', () => {
    expect(dayKey(new Date(2026, 6, 8))).toBe('2026-07-08');
    expect(dayKey(new Date(2026, 0, 3))).toBe('2026-01-03');
  });

  it('stays on the local day near midnight (no UTC shift)', () => {
    expect(dayKey(new Date(2026, 6, 8, 0, 5))).toBe('2026-07-08');
    expect(dayKey(new Date(2026, 6, 8, 23, 55))).toBe('2026-07-08');
  });
});

describe('workWeekFor', () => {
  it('returns Mon–Fri containing a midweek anchor', () => {
    // 2026-07-08 is a Wednesday.
    const days = workWeekFor(new Date(2026, 6, 8));
    expect(days.map(dayKey)).toEqual([
      '2026-07-06',
      '2026-07-07',
      '2026-07-08',
      '2026-07-09',
      '2026-07-10'
    ]);
  });

  it('keeps a Monday anchor as the first column', () => {
    expect(dayKey(workWeekFor(new Date(2026, 6, 6))[0])).toBe('2026-07-06');
  });

  it('maps weekend anchors to the week just ended (ISO Monday start)', () => {
    // 2026-07-12 is a Sunday; its ISO week began Monday the 6th.
    expect(dayKey(workWeekFor(new Date(2026, 6, 12))[0])).toBe('2026-07-06');
    // Saturday the 11th likewise.
    expect(dayKey(workWeekFor(new Date(2026, 6, 11))[0])).toBe('2026-07-06');
  });

  it('crosses month boundaries', () => {
    // 2026-07-01 is a Wednesday; the week starts Monday June 29.
    const days = workWeekFor(new Date(2026, 6, 1));
    expect(days.map(dayKey)).toEqual([
      '2026-06-29',
      '2026-06-30',
      '2026-07-01',
      '2026-07-02',
      '2026-07-03'
    ]);
  });
});

describe('addDays', () => {
  it('returns local midnight of the shifted day', () => {
    const shifted = addDays(new Date(2026, 6, 8, 15, 30), 2);
    expect(dayKey(shifted)).toBe('2026-07-10');
    expect(shifted.getHours()).toBe(0);
  });
});

describe('dateFromKey', () => {
  it('round-trips with dayKey at local midnight', () => {
    const date = dateFromKey('2026-07-08');
    expect(dayKey(date)).toBe('2026-07-08');
    expect(date.getHours()).toBe(0);
  });
});

describe('addMonths', () => {
  it('moves by whole months keeping the day', () => {
    expect(dayKey(addMonths(new Date(2026, 6, 12), 1))).toBe('2026-08-12');
    expect(dayKey(addMonths(new Date(2026, 6, 12), -1))).toBe('2026-06-12');
  });

  it('clamps the day to the target month length', () => {
    expect(dayKey(addMonths(new Date(2026, 0, 31), 1))).toBe('2026-02-28');
    expect(dayKey(addMonths(new Date(2028, 0, 31), 1))).toBe('2028-02-29'); // leap year
  });

  it('crosses year boundaries', () => {
    expect(dayKey(addMonths(new Date(2026, 11, 15), 1))).toBe('2027-01-15');
  });
});

describe('monthGridFor', () => {
  it('covers July 2026 in five Monday-start rows with padded edges', () => {
    const weeks = monthGridFor(new Date(2026, 6, 12));
    expect(weeks).toHaveLength(5);
    expect(dayKey(weeks[0][0])).toBe('2026-06-29'); // Jul 1 is a Wednesday
    expect(dayKey(weeks[4][6])).toBe('2026-08-02'); // Jul 31 is a Friday
    expect(weeks.every((w) => w.length === 7)).toBe(true);
  });

  it('renders a Monday-first 28-day February in exactly four rows', () => {
    const weeks = monthGridFor(new Date(2027, 1, 10)); // Feb 2027 starts Monday
    expect(weeks).toHaveLength(4);
    expect(dayKey(weeks[0][0])).toBe('2027-02-01');
    expect(dayKey(weeks[3][6])).toBe('2027-02-28');
  });

  it('stretches to six rows when the month demands it', () => {
    const weeks = monthGridFor(new Date(2026, 2, 15)); // Mar 2026 starts Sunday, 31 days
    expect(weeks).toHaveLength(6);
    expect(dayKey(weeks[0][0])).toBe('2026-02-23');
    expect(dayKey(weeks[5][6])).toBe('2026-04-05');
  });
});

describe('monthLabel', () => {
  it('renders month and year', () => {
    expect(monthLabel(new Date(2026, 6, 12))).toBe('July 2026');
  });
});

describe('rangeLabel', () => {
  it('renders a same-month work week', () => {
    expect(rangeLabel(workWeekFor(new Date(2026, 6, 8)))).toBe('July 6 – 10');
  });

  it('renders a cross-month week with both months', () => {
    expect(rangeLabel(workWeekFor(new Date(2026, 6, 1)))).toBe('June 29 – July 3');
  });

  it('renders a single day long-form', () => {
    expect(rangeLabel([new Date(2026, 6, 8)])).toBe('Wednesday, July 8');
  });

  it('is empty for no days', () => {
    expect(rangeLabel([])).toBe('');
  });
});

describe('dayHeaderParts', () => {
  it('splits weekday and day number', () => {
    expect(dayHeaderParts(new Date(2026, 6, 8))).toEqual({ weekday: 'Wed', day: 8 });
  });
});

describe('hourWindow', () => {
  it('defaults to the 9–17 base band with no events', () => {
    expect(hourWindow([])).toEqual({ startMin: 540, endMin: 1020 });
  });

  it('never shrinks below the base band', () => {
    const w = hourWindow([ev({ startMin: 10 * 60, endMin: 11 * 60 })]);
    expect(w).toEqual(BASE_WINDOW);
  });

  it('stretches and rounds to whole hours around outlying events', () => {
    const w = hourWindow([ev({ startMin: 8 * 60 + 30, endMin: 17 * 60 + 45 })]);
    expect(w).toEqual({ startMin: 8 * 60, endMin: 18 * 60 });
  });

  it('clamps to the local day', () => {
    const w = hourWindow([ev({ startMin: -30, endMin: 24 * 60 + 30 })]);
    expect(w).toEqual({ startMin: 0, endMin: 24 * 60 });
  });
});

describe('gutterHours', () => {
  it('labels every hour line from the top edge to just above the bottom edge', () => {
    expect(gutterHours({ startMin: 540, endMin: 1080 })).toEqual([9, 10, 11, 12, 13, 14, 15, 16, 17]);
  });
});

describe('eventBox', () => {
  const window = { startMin: 540, endMin: 1080 }; // 9:00–18:00

  it('positions an event proportionally', () => {
    const box = eventBox({ startMin: 11 * 60, endMin: 12 * 60 + 15 }, window);
    expect(box.topPct).toBeCloseTo(((660 - 540) / 540) * 100);
    expect(box.heightPct).toBeCloseTo((75 / 540) * 100);
  });

  it('clamps events that spill past the window edges', () => {
    const box = eventBox({ startMin: 8 * 60, endMin: 19 * 60 }, window);
    expect(box.topPct).toBe(0);
    expect(box.heightPct).toBe(100);
  });
});

describe('nowOffsetPct', () => {
  const window = { startMin: 540, endMin: 1080 };

  it('is proportional inside the window', () => {
    expect(nowOffsetPct(810, window)).toBeCloseTo(50);
  });

  it('is null outside the window', () => {
    expect(nowOffsetPct(500, window)).toBeNull();
    expect(nowOffsetPct(1100, window)).toBeNull();
  });
});

describe('isPastEvent', () => {
  const now = new Date(2026, 6, 8, 14, 0);

  it('is past for earlier days and ended-today events', () => {
    expect(isPastEvent(ev({ day: '2026-07-07' }), now)).toBe(true);
    expect(isPastEvent(ev({ day: '2026-07-08', startMin: 660, endMin: 720 }), now)).toBe(true);
  });

  it('is not past for running or upcoming events', () => {
    expect(isPastEvent(ev({ day: '2026-07-08', startMin: 810, endMin: 900 }), now)).toBe(false);
    expect(isPastEvent(ev({ day: '2026-07-09', startMin: 540, endMin: 600 }), now)).toBe(false);
  });
});

describe('labels', () => {
  it('renders 24h times without a leading hour zero', () => {
    expect(timeLabel(9 * 60)).toBe('9:00');
    expect(timeLabel(16 * 60 + 30)).toBe('16:30');
  });

  it('renders ranges with an en dash', () => {
    expect(timeRangeLabel(11 * 60, 12 * 60 + 15)).toBe('11:00 – 12:15');
  });

  it('exposes minutes of day for the now line', () => {
    expect(minutesOfDay(new Date(2026, 6, 8, 9, 30))).toBe(570);
  });
});

// -- occurrenceToGridEvents (Spec F adapter) ----------------------------------

import { localParts, occurrenceKind, occurrenceToGridEvents, type CalendarOccurrence } from './calendar-shapes';

function row(partial: Partial<CalendarOccurrence>): CalendarOccurrence {
  return {
    source: 'work',
    all_day: false,
    start: '2026-07-21T07:30:00Z',
    end: '2026-07-21T08:00:00Z',
    summary: 'Standup',
    location: null,
    status: 'confirmed',
    description: null,
    view_path: 'sources/calendar/work/views/events/ev-0000000000000000.md',
    path: null,
    ...partial
  };
}

describe('occurrenceToGridEvents', () => {
  it('converts a timed UTC row to host-local wall minutes (Zurich, CEST +02:00)', () => {
    const { segments, allDay } = occurrenceToGridEvents(row({}), 'Europe/Zurich');
    expect(allDay).toEqual([]);
    expect(segments).toHaveLength(1);
    expect(segments[0].day).toBe('2026-07-21');
    expect(segments[0].startMin).toBe(9 * 60 + 30);
    expect(segments[0].endMin).toBe(10 * 60);
    expect(segments[0].kind).toBe('booked');
  });

  it('lands a UTC-evening instant on the NEXT local day in a positive-offset zone', () => {
    const { segments } = occurrenceToGridEvents(
      row({ start: '2026-07-21T22:30:00Z', end: '2026-07-21T23:00:00Z' }),
      'Europe/Zurich'
    );
    expect(segments).toHaveLength(1);
    expect(segments[0].day).toBe('2026-07-22');
    expect(segments[0].startMin).toBe(30);
  });

  it('lands a UTC-morning instant on the PREVIOUS local day in a negative-offset zone', () => {
    const { segments } = occurrenceToGridEvents(
      row({ start: '2026-07-21T02:00:00Z', end: '2026-07-21T03:00:00Z' }),
      'America/New_York'
    );
    expect(segments).toHaveLength(1);
    expect(segments[0].day).toBe('2026-07-20');
    expect(segments[0].startMin).toBe(22 * 60);
  });

  it('splits a multi-day timed occurrence into per-local-day segments', () => {
    const { segments } = occurrenceToGridEvents(
      row({ start: '2026-07-21T20:00:00Z', end: '2026-07-23T06:00:00Z' }),
      'Europe/Zurich'
    );
    expect(segments.map((s) => [s.day, s.startMin, s.endMin])).toEqual([
      ['2026-07-21', 22 * 60, 24 * 60],
      ['2026-07-22', 0, 24 * 60],
      ['2026-07-23', 0, 8 * 60]
    ]);
    expect(new Set(segments.map((s) => s.id)).size).toBe(3);
  });

  it('closes an exact-local-midnight end on the previous day (no empty trailing segment)', () => {
    const { segments } = occurrenceToGridEvents(
      row({ start: '2026-07-21T20:00:00Z', end: '2026-07-21T22:00:00Z' }),
      'Europe/Zurich'
    );
    expect(segments.map((s) => [s.day, s.startMin, s.endMin])).toEqual([['2026-07-21', 22 * 60, 24 * 60]]);
  });

  it('uses all-day plain dates DIRECTLY with the exclusive end (no zone conversion)', () => {
    const { segments, allDay } = occurrenceToGridEvents(
      row({ all_day: true, start: '2026-07-21', end: '2026-07-24' }),
      'America/New_York' // a negative-offset zone must NOT shift the days
    );
    expect(segments).toEqual([]);
    expect(allDay.map((e) => e.day)).toEqual(['2026-07-21', '2026-07-22', '2026-07-23']);
  });

  it('renders a one-day all-day event as exactly one chip', () => {
    const { allDay } = occurrenceToGridEvents(row({ all_day: true, start: '2026-07-21', end: '2026-07-22' }), 'UTC');
    expect(allDay).toHaveLength(1);
    expect(allDay[0].day).toBe('2026-07-21');
    expect(allDay[0].cancelled).toBe(false);
  });

  it('maps kinds per the spec: tentative → hold, valea → block, cancelled valea flagged', () => {
    expect(occurrenceKind(row({ status: 'tentative' }))).toBe('hold');
    expect(occurrenceKind(row({ source: 'valea', path: 'sources/calendar/valea/events/x.md', view_path: null }))).toBe(
      'block'
    );
    const { allDay } = occurrenceToGridEvents(
      row({ source: 'valea', status: 'cancelled', all_day: true, start: '2026-07-21', end: '2026-07-22' }),
      'UTC'
    );
    expect(allDay[0].cancelled).toBe(true);
    expect(allDay[0].kind).toBe('block');
  });

  it('keeps DST-day segments honest (spring-forward day is 23h in Zurich)', () => {
    // 2026-03-29 02:00 CET jumps to 03:00 CEST. 00:00Z = 01:00 local; 04:00Z = 06:00 local.
    const { segments } = occurrenceToGridEvents(
      row({ start: '2026-03-29T00:00:00Z', end: '2026-03-29T04:00:00Z' }),
      'Europe/Zurich'
    );
    expect(segments).toHaveLength(1);
    expect(segments[0].startMin).toBe(60);
    expect(segments[0].endMin).toBe(6 * 60);
  });
});

describe('localParts', () => {
  it('is stable across the h23 midnight edge (00, never 24)', () => {
    expect(localParts('2026-07-21T22:00:00Z', 'Europe/Zurich')).toEqual({ day: '2026-07-22', minutes: 0 });
  });
});
