/**
 * View helpers shared by the Today page's pieces. Relocated out of
 * `routes/+page.svelte` when the attention and briefing cards became
 * components (Today/Tasks redesign): the same stamp is formatted by the route
 * and by both cards, and a third copy is how two of them drift apart.
 *
 * Everything here is PURE — the page's decisions (what the tail line says, how
 * the rail merges two mailboxes, which event is next) are pinned by
 * `today-view.test.ts` rather than by reading markup, the same split
 * `components/tasks/task-shapes.ts` and `components/calendar/calendar-shapes.ts`
 * keep.
 */
import { timeLabel, type CalendarEvent } from '../components/calendar/calendar-shapes';
import { ledgerNote, type LedgerStatusLike } from '../components/tasks/task-shapes';
import type { MailAccountSummary, TodaySection } from './cockpit';

/**
 * "Aug 6, 09:30" — the one timestamp shape Today uses, in the viewer's own
 * locale and zone. A string that is not a date is returned UNCHANGED rather
 * than rendered as "Invalid Date": these stamps come out of user-owned files
 * (`today.json`) and a mangled one should show what it actually says.
 */
export function formatTimestamp(iso: string): string {
  const parsed = new Date(iso);
  if (Number.isNaN(parsed.getTime())) return iso;
  return parsed.toLocaleString(undefined, {
    month: 'short',
    day: 'numeric',
    hour: '2-digit',
    minute: '2-digit'
  });
}

/**
 * Whether an ICM's briefing file actually SAYS anything — the predicate
 * `AgentBriefingCard` self-guards on, exported so the whole-page empty state can
 * ask the same question of the same sections. Two copies of it is how the
 * welcome card ends up under a briefing card (or hidden behind an empty one).
 *
 * Truthiness, not `!== null`: `"notes": ""` normalizes to an empty STRING, which
 * the card body renders as nothing just like a missing key.
 */
export function hasBriefing(section: TodaySection): boolean {
  return Boolean(section.notes) || section.prepared.length > 0;
}

/**
 * The calm note for every task ledger Valea could not parse, project-named.
 *
 * Today merges the ledgers into one list, so an unreadable `tasks.json`
 * contributes NO rows — and a page that then said nothing about it would be
 * claiming a quiet day over a broken file, which the leniency contract forbids
 * outright (an empty ledger is a fact about the user's files; an unreadable one
 * is not). The wording is `TasksTab`'s, through the same `ledgerNote`, with the
 * project prefix its own stray-notes block uses — the two surfaces must not
 * describe one file two ways.
 *
 * It is the whole answer to "does the tasks section have something to say":
 * the caller renders these notes, keeps the section alive for them, and drops
 * the whole-page empty state while any of them stands.
 *
 * Each note rides with the MOUNT KEY it came from, and that — not the sentence —
 * is what the renderer keys its list on: two projects can carry the same
 * `icmName` (the manifest does not police display names), and their notes are
 * then character-for-character identical. A sentence-keyed `#each` over that
 * pair throws `each_key_duplicate` in production. Mount keys are uniquified
 * backend-side, so they cannot collide.
 */
export function unreadableLedgerNotes(
  icms: { mountKey: string; icmName: string; status: LedgerStatusLike }[]
): { mountKey: string; note: string }[] {
  return icms.flatMap((icm) => {
    const note = ledgerNote(icm.status);
    if (note === null) return [];
    return [{ mountKey: icm.mountKey, note: `${icm.icmName || icm.mountKey}: tasks.json is ${note}` }];
  });
}

/** One part of the tasks section's tail line; `emphasis` is the link, everything else is quiet meta. */
export type TailSegment = { text: string; emphasis: boolean };

/**
 * The tail under Today's task list (spec §Today's tasks): what is NOT on the
 * page, and one way to go deal with it.
 *
 * `backlogCount` is open work outside the today view under the current assignee
 * toggle; `hiddenAssistantCount` is today-view work the `Mine` toggle is
 * hiding — the toggle never silently lies about rows it removed. Zero parts
 * drop, and with both at zero the whole line goes: nothing is being withheld,
 * so there is nothing to link away to.
 */
export function todayTailSegments(input: { backlogCount: number; hiddenAssistantCount: number }): TailSegment[] {
  const segments: TailSegment[] = [];
  if (input.backlogCount > 0) segments.push({ text: `${input.backlogCount} more in the backlog`, emphasis: false });
  if (input.hiddenAssistantCount > 0) {
    segments.push({ text: `${input.hiddenAssistantCount} with the assistant`, emphasis: false });
  }
  if (segments.length > 0) segments.push({ text: 'Plan today →', emphasis: true });
  return segments;
}

/** One rail mail row: which account it came from, the message to deep-link, and the single line the card shows. */
export type RailMailRow = { account: string; msgId: string; line: string };

/**
 * The rail's mail card, merged across accounts and newest first.
 *
 * The cockpit hands one unread list PER ACCOUNT, each already newest-first and
 * capped backend-side; the rail shows one short list, so the accounts are
 * interleaved by `date` here. A row with no date — or one whose date is not a
 * date, since these strings come off the wire — sorts LAST rather than being
 * dropped: an unread message is a fact, and its stamp is not.
 *
 * The line is `<sender> — <subject>`, both with their own fallbacks, and
 * truncation is left to CSS (the rail is 300px and the card knows its width;
 * this function does not).
 */
export function railMailRows(mail: MailAccountSummary[], cap: number): RailMailRow[] {
  const rows = mail.flatMap((entry) =>
    entry.unread.map((message) => ({
      account: entry.account,
      msgId: message.msgId,
      line: `${message.fromName ?? message.fromEmail ?? message.subject ?? '(unknown)'} — ${message.subject ?? '(no subject)'}`,
      at: message.date === null ? NaN : Date.parse(message.date)
    }))
  );
  // `Array.prototype.sort` is stable per spec, so undated rows keep the order
  // their accounts arrived in rather than shuffling on every render.
  return rows
    .sort((a, b) => {
      if (Number.isNaN(a.at) && Number.isNaN(b.at)) return 0;
      if (Number.isNaN(a.at)) return 1;
      if (Number.isNaN(b.at)) return -1;
      return b.at - a.at;
    })
    .slice(0, cap)
    .map(({ account, msgId, line }) => ({ account, msgId, line }));
}

/**
 * "45 min" / "2 h" / "1 h 30 min", or `null` when the event has no length to
 * report — a zero-length or inverted span says nothing, and a "0 min" chip on
 * an agenda row is noise (`schedule-shapes.ts`'s `durationLabel` makes the same
 * call about a run that recorded no duration).
 */
function agendaDuration(min: number): string | null {
  if (min <= 0) return null;
  if (min < 60) return `${min} min`;
  const hours = Math.floor(min / 60);
  const minutes = min % 60;
  return minutes === 0 ? `${hours} h` : `${hours} h ${minutes} min`;
}

/** One agenda line: the clock, the title, how long it runs, and whether it was called off. */
export type AgendaRow = { time: string; title: string; duration: string | null; cancelled: boolean };

/**
 * Today's timed events as agenda lines, earliest first.
 *
 * TIMED only: the caller normalizes wire rows through `occurrenceToGridEvents`,
 * whose all-day entries land in a separate lane and carry no clock time — the
 * same reading `Valea.Cockpit`'s own `next_event/3` takes when it filters
 * `all_day` rows out of the "next" line.
 *
 * Cancelled rows STAY, struck through, exactly as the week and month grids
 * render them: a meeting that was called off is still a fact about the day (the
 * hour it freed is the point), and dropping it from the agenda alone would make
 * two views of the same calendar disagree. Only VALEA cancellations arrive —
 * external ones are removed at expansion.
 */
export function agendaRows(events: CalendarEvent[]): AgendaRow[] {
  return [...events]
    .sort((a, b) => a.startMin - b.startMin)
    .map((event) => ({
      time: timeLabel(event.startMin),
      title: event.title,
      duration: agendaDuration(event.endMin - event.startMin),
      cancelled: event.cancelled === true
    }));
}

/**
 * The header's `next event HH:MM` — the first NON-CANCELLED event starting at or
 * after `nowMin` (minutes from local midnight, via `minutesOfDay`). An event
 * starting exactly now IS next: it has not begun before now, and rounding it
 * away would make the line skip the meeting the user is walking into.
 *
 * A cancelled event is not somewhere to be, so it cannot be what is next — the
 * agenda still lists it struck through, but the header would be sending the user
 * to a meeting that isn't happening.
 */
export function nextEventTime(events: CalendarEvent[], nowMin: number): string | null {
  const upcoming = events
    .filter((event) => event.cancelled !== true && event.startMin >= nowMin)
    .sort((a, b) => a.startMin - b.startMin);
  return upcoming.length === 0 ? null : timeLabel(upcoming[0].startMin);
}
