import { describe, expect, it } from 'vitest';
import type { CalendarEvent } from '../components/calendar/calendar-shapes';
import type { MailAccountSummary, MailUnreadMessage, TodaySection } from './cockpit';
import {
  agendaRows,
  formatTimestamp,
  hasBriefing,
  nextEventTime,
  railMailRows,
  todayTailSegments
} from './today-view';

function message(over: Partial<MailUnreadMessage> & { msgId: string }): MailUnreadMessage {
  return { fromName: null, fromEmail: null, subject: null, date: null, ...over };
}

function account(name: string, unread: MailUnreadMessage[], unreadCount = unread.length): MailAccountSummary {
  return { account: name, configured: true, state: 'idle', pendingOps: 0, notices: [], unread, unreadCount };
}

function event(over: Partial<CalendarEvent> & { startMin: number; endMin: number }): CalendarEvent {
  return { id: `e${over.startMin}`, title: 'Standup', day: '2026-08-06', kind: 'booked', ...over };
}

function section(over: Partial<TodaySection>): TodaySection {
  return {
    mountKey: 'work',
    icmName: 'Work',
    todayJson: 'present',
    updatedAt: null,
    notes: null,
    prepared: [],
    tasks: null,
    ...over
  };
}

describe('todayTailSegments', () => {
  it('composes both counts plus the always-present call to action', () => {
    expect(todayTailSegments({ backlogCount: 31, hiddenAssistantCount: 1 })).toEqual([
      { text: '31 more in the backlog', emphasis: false },
      { text: '1 with the assistant', emphasis: false },
      { text: 'Plan today →', emphasis: true }
    ]);
  });

  it('drops a zero part but keeps the call to action while either count stands', () => {
    expect(todayTailSegments({ backlogCount: 4, hiddenAssistantCount: 0 })).toEqual([
      { text: '4 more in the backlog', emphasis: false },
      { text: 'Plan today →', emphasis: true }
    ]);
    expect(todayTailSegments({ backlogCount: 0, hiddenAssistantCount: 2 })).toEqual([
      { text: '2 with the assistant', emphasis: false },
      { text: 'Plan today →', emphasis: true }
    ]);
  });

  it('says nothing at all when both counts are zero', () => {
    expect(todayTailSegments({ backlogCount: 0, hiddenAssistantCount: 0 })).toEqual([]);
  });
});

describe('railMailRows', () => {
  const work = account('work', [
    message({ msgId: 'a', fromName: 'Ana', subject: 'Invoice', date: '2026-08-06T09:00:00Z' }),
    message({ msgId: 'b', fromEmail: 'bo@example.test', date: '2026-08-06T07:30:00Z' })
  ]);
  const home = account('home', [
    message({ msgId: 'c', fromName: 'Cy', subject: 'Trip', date: '2026-08-06T11:00:00Z' })
  ]);

  it('merges the accounts newest first and stamps each row with its account', () => {
    expect(railMailRows([work, home], 4)).toEqual([
      { account: 'home', msgId: 'c', line: 'Cy — Trip' },
      { account: 'work', msgId: 'a', line: 'Ana — Invoice' },
      { account: 'work', msgId: 'b', line: 'bo@example.test — (no subject)' }
    ]);
  });

  it('sorts undated and unparseable-dated rows last, in the order they arrived', () => {
    const undated = account('work', [
      message({ msgId: 'x', fromName: 'X', subject: 'X' }),
      message({ msgId: 'y', fromName: 'Y', subject: 'Y', date: 'not a date' }),
      message({ msgId: 'z', fromName: 'Z', subject: 'Z', date: '2026-08-06T09:00:00Z' })
    ]);
    expect(railMailRows([undated], 4).map((row) => row.msgId)).toEqual(['z', 'x', 'y']);
  });

  it('caps the merged list', () => {
    expect(railMailRows([work, home], 2).map((row) => row.msgId)).toEqual(['c', 'a']);
  });

  it('falls back down the sender chain and then to the subject', () => {
    expect(railMailRows([account('work', [message({ msgId: 's', subject: 'Only a subject' })])], 4)).toEqual([
      { account: 'work', msgId: 's', line: 'Only a subject — Only a subject' }
    ]);
    expect(railMailRows([account('work', [message({ msgId: 'n' })])], 4)).toEqual([
      { account: 'work', msgId: 'n', line: '(unknown) — (no subject)' }
    ]);
  });
});

describe('agendaRows', () => {
  it('sorts by start and labels time and duration', () => {
    expect(
      agendaRows([
        event({ startMin: 600, endMin: 720, title: 'Design review' }),
        event({ startMin: 555, endMin: 600, title: 'Standup' }),
        event({ startMin: 900, endMin: 990, title: 'Interview' })
      ])
    ).toEqual([
      { time: '9:15', title: 'Standup', duration: '45 min' },
      { time: '10:00', title: 'Design review', duration: '2 h' },
      { time: '15:00', title: 'Interview', duration: '1 h 30 min' }
    ]);
  });

  it('has no duration for a zero-length or inverted event', () => {
    expect(agendaRows([event({ startMin: 780, endMin: 780, title: 'Ping' })])).toEqual([
      { time: '13:00', title: 'Ping', duration: null }
    ]);
    expect(agendaRows([event({ startMin: 780, endMin: 700, title: 'Ping' })])[0].duration).toBeNull();
  });
});

describe('nextEventTime', () => {
  const events = [event({ startMin: 660, endMin: 720 }), event({ startMin: 540, endMin: 600 })];

  it('includes an event starting exactly now', () => {
    expect(nextEventTime(events, 540)).toBe('9:00');
  });

  it('takes the earliest still-upcoming event whatever order it arrived in', () => {
    expect(nextEventTime(events, 541)).toBe('11:00');
  });

  it('is null when nothing is upcoming', () => {
    expect(nextEventTime(events, 661)).toBeNull();
    expect(nextEventTime([], 0)).toBeNull();
  });
});

describe('hasBriefing', () => {
  it('is true for a section with notes or prepared work', () => {
    expect(hasBriefing(section({ notes: 'Two calls today.' }))).toBe(true);
    expect(hasBriefing(section({ prepared: [{ title: 'Draft', summary: null, page: null }] }))).toBe(true);
  });

  it('is false for a briefing file that says nothing — an empty string included', () => {
    expect(hasBriefing(section({}))).toBe(false);
    expect(hasBriefing(section({ notes: '' }))).toBe(false);
  });
});

describe('formatTimestamp', () => {
  it('returns a non-date string unchanged', () => {
    expect(formatTimestamp('sometime')).toBe('sometime');
  });
});
