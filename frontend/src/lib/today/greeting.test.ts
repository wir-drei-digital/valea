import { describe, expect, it } from 'vitest';
import { daySummarySegments, dateOverline, greetingForHour } from './greeting';

describe('greetingForHour', () => {
  it('morning 5–11, afternoon 12–17, evening otherwise', () => {
    expect(greetingForHour(5)).toBe('Good morning');
    expect(greetingForHour(11)).toBe('Good morning');
    expect(greetingForHour(12)).toBe('Good afternoon');
    expect(greetingForHour(17)).toBe('Good afternoon');
    expect(greetingForHour(18)).toBe('Good evening');
    expect(greetingForHour(2)).toBe('Good evening');
  });
});

describe('dateOverline', () => {
  it('renders weekday, month, day (en-locale pin for the test)', () => {
    expect(dateOverline(new Date(2026, 7, 6), 'en-US')).toBe('Thursday, August 6');
  });
});

describe('daySummarySegments', () => {
  it('composes all four parts with tones', () => {
    expect(
      daySummarySegments({ todayCount: 3, overdueCount: 2, attentionCount: 1, nextEventTime: '09:30' })
    ).toEqual([
      { text: '3 tasks for today', tone: 'meta' },
      { text: '2 overdue', tone: 'warn' },
      { text: '1 thing needs your attention', tone: 'meta' },
      { text: 'next event 09:30', tone: 'meta' }
    ]);
  });
  it('drops zero/absent parts and pluralizes', () => {
    expect(daySummarySegments({ todayCount: 1, overdueCount: 0, attentionCount: 2, nextEventTime: null })).toEqual([
      { text: '1 task for today', tone: 'meta' },
      { text: '2 things need your attention', tone: 'meta' }
    ]);
    expect(daySummarySegments({ todayCount: 0, overdueCount: 0, attentionCount: 0, nextEventTime: null })).toEqual([]);
  });
});
