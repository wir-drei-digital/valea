/**
 * Types + normalizer for the Spec-D cockpit payload (`cockpit_today` RPC):
 * per-ICM sections read from `today.json` files agents maintain, plus the
 * live state Valea owns (mail counts, recent sessions). The normalizer
 * accepts BOTH snake_case and camelCase keys, same defensive stance the
 * previous revision took toward the generic-action map boundary.
 */
import { normalizeGitRepoRows, type GitRepoStatus } from '../stores/git.svelte';

export type TodayPrepared = { title: string | null; summary: string | null; page: string | null };
/** One of the tasks line's top items — ordered today-flag first, then due, then priority, backend-side. */
export type TodayTopTask = {
  id: string | null;
  title: string | null;
  due: string | null;
  today: boolean;
  priority: string | null;
};
/**
 * The section's tasks line (tasks+schedules spec §Cockpit) — the counts +
 * top-items block that REPLACED `open_loops`, read off `tasks.json` rather than
 * `today.json`.
 */
export type TodayTasks = {
  dueToday: number;
  overdue: number;
  inProgress: number;
  top: TodayTopTask[];
};
/**
 * What happened to the ICM's `today.json` — the state that REPLACED the `ok`
 * boolean (Today/Tasks redesign). Every enabled ICM now gets a section, so the
 * briefing file's fate is a field rather than the section's existence:
 * `present` renders the agent's card, `unreadable` the calm one-line note,
 * `absent` nothing at all.
 */
export type TodayJsonState = 'present' | 'absent' | 'unreadable';
export type TodaySection = {
  mountKey: string;
  icmName: string;
  todayJson: TodayJsonState;
  updatedAt: string | null;
  notes: string | null;
  prepared: TodayPrepared[];
  /**
   * `null` for an UNREADABLE task ledger — the calm "fix by hand" note — and a
   * zeroed line for an absent or empty one. That difference is the whole point:
   * "nothing to do" and "I cannot read your file" are not the same answer, and
   * the ledger degrades on its own (`todayJson` above stays about `today.json`).
   */
  tasks: TodayTasks | null;
};
/**
 * A schedule notice (tasks+schedules spec §Cockpit): parked (`waiting`),
 * `failed`, and newly `registered` schedules from the last 24 h, across every
 * enabled ICM. NO captured output rides here — `schedule_run_history` is where
 * output lives.
 */
export type ScheduleNotice = {
  kind: 'waiting' | 'failed' | 'registered' | string;
  /** `null` only when the ICM is no longer mounted at all. */
  mountKey: string | null;
  scheduleId: string;
  title: string;
  at: string | null;
};
export type RecentSession = {
  id: string;
  title: string;
  startedAt: string;
  status: string;
  live: boolean;
};
/** One unread-INBOX row of a mail account's cockpit entry ("new emails by account"). */
export type MailUnreadMessage = {
  msgId: string;
  fromName: string | null;
  fromEmail: string | null;
  subject: string | null;
  date: string | null;
};
/** One configured account's cockpit line (`Valea.Cockpit.mail_summary/0` — per-account since the mail-as-maildir rework). */
export type MailAccountSummary = {
  account: string;
  configured: boolean;
  state: string;
  pendingOps: number;
  notices: string[];
  /** Unread INBOX messages within the cockpit's recency window (newest first, capped backend-side). */
  unread: MailUnreadMessage[];
  unreadCount: number;
};
/** The cockpit calendar line (`Valea.Cockpit.calendar_summary/0`, Spec F) — `null` when the subsystem has nothing to say. */
export type CalendarSummary = {
  eventsToday: number;
  next: { time: string; title: string } | null;
};
export type CockpitToday = {
  sections: TodaySection[];
  mail: MailAccountSummary[];
  calendar: CalendarSummary | null;
  recentSessions: RecentSession[];
  scheduleNotices: ScheduleNotice[];
  /**
   * Every git-capable ICM's sync row (ICM git sync spec §UI) — the SAME
   * `Valea.Git.Engine.public_rows/1` rows the `git_status` RPC and push
   * carry, so `stores/git.svelte.ts` owns both the type and the normalizer
   * and this block is just a third delivery of them.
   *
   * Normalized here because the payload carries it and the shape is worth
   * pinning, but NOTHING renders it: `gitStore` is the single source of truth
   * for git rows, fed only by its own RPC and the `git_status` push. This
   * block is read from the same last-completed-pass cache the RPC reads, so
   * it is never fresher — and a cockpit reply that lands after a push would
   * re-install rows that push had already superseded. See `GitStore`'s
   * ordering note and `routes/+page.svelte`'s `refresh`.
   */
  git: GitRepoStatus[];
};

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
}

/** Same defensive-degrade stance as `str()` above, for numeric fields: non-numeric raw input degrades to 0 rather than propagating `NaN`. */
function num(v: unknown): number {
  const n = Number(v ?? 0);
  return Number.isFinite(n) ? n : 0;
}

function pick(raw: Record<string, unknown>, snake: string, camel: string): unknown {
  return raw[snake] !== undefined ? raw[snake] : raw[camel];
}

/**
 * The tasks line. `sections[].tasks` is a NESTED plain `:map`, and the
 * ash_typescript runtime extraction only renames fields of ARRAY items — a
 * nested map comes back with its SOURCE keys (`due_today`, `in_progress`), even
 * though the emitted TS types camelCase them. Pinned by
 * `test/valea_web/rpc_test.exs`; `pick` handles either spelling, same as the
 * calendar line above it.
 *
 * `null` (an unreadable ledger) stays `null` — the caller renders the calm note
 * rather than a zeroed line, which would read as "nothing to do".
 */
function normalizeTasksLine(raw: unknown): TodayTasks | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const rec = raw as Record<string, unknown>;
  const top = pick(rec, 'top', 'top');
  return {
    dueToday: num(pick(rec, 'due_today', 'dueToday')),
    overdue: num(pick(rec, 'overdue', 'overdue')),
    inProgress: num(pick(rec, 'in_progress', 'inProgress')),
    top: (Array.isArray(top) ? top : [])
      .filter((t): t is Record<string, unknown> => typeof t === 'object' && t !== null)
      .map((t) => ({
        id: str(t.id),
        title: str(t.title),
        due: str(t.due),
        today: t.today === true,
        priority: str(t.priority)
      }))
  };
}

/**
 * The briefing file's state, with the spec's two-sided leniency: a MISSING
 * field degrades quiet (`absent` — an old or trimmed payload renders nothing,
 * not a scary note), while a field that is present but says something we do not
 * know degrades honest (`unreadable` — we cannot vouch for that briefing, and
 * the calm note says so). Never throws either way.
 */
function normalizeTodayJson(raw: Record<string, unknown>): TodayJsonState {
  const value = pick(raw, 'today_json', 'todayJson');
  if (value === 'present' || value === 'absent' || value === 'unreadable') return value;
  return value === undefined ? 'absent' : 'unreadable';
}

function normalizeSection(raw: Record<string, unknown>): TodaySection {
  const prepared = Array.isArray(raw.prepared) ? raw.prepared : [];
  return {
    mountKey: str(pick(raw, 'mount_key', 'mountKey')) ?? '',
    icmName: str(pick(raw, 'icm_name', 'icmName')) ?? '',
    todayJson: normalizeTodayJson(raw),
    updatedAt: str(pick(raw, 'updated_at', 'updatedAt')),
    notes: str(raw.notes),
    prepared: prepared
      .filter((p): p is Record<string, unknown> => typeof p === 'object' && p !== null)
      .map((p) => ({ title: str(p.title), summary: str(p.summary), page: str(p.page) })),
    tasks: normalizeTasksLine(pick(raw, 'tasks', 'tasks'))
  };
}

/**
 * Notices are a TOP-LEVEL array, so their item fields DO arrive camelCased
 * (`scheduleId`) — the other half of the same extraction asymmetry. Both
 * spellings are accepted anyway. A notice with no `schedule_id` is dropped: it
 * could not be linked anywhere.
 */
function normalizeScheduleNotices(raw: unknown): ScheduleNotice[] {
  return (Array.isArray(raw) ? raw : [])
    .filter((n): n is Record<string, unknown> => typeof n === 'object' && n !== null)
    .flatMap((n) => {
      const scheduleId = str(pick(n, 'schedule_id', 'scheduleId'));
      const kind = str(n.kind);
      if (scheduleId === null || kind === null) return [];
      return [
        {
          kind,
          mountKey: str(pick(n, 'mount_key', 'mountKey')),
          scheduleId,
          title: str(n.title) ?? scheduleId,
          at: str(n.at)
        }
      ];
    });
}

function normalizeCalendarSummary(raw: unknown): CalendarSummary | null {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const rec = raw as Record<string, unknown>;
  const next = pick(rec, 'next', 'next');
  const nextRec =
    next && typeof next === 'object' && !Array.isArray(next) ? (next as Record<string, unknown>) : null;
  return {
    eventsToday: num(pick(rec, 'events_today', 'eventsToday')),
    next:
      nextRec && typeof nextRec.time === 'string' && typeof nextRec.title === 'string'
        ? { time: nextRec.time, title: nextRec.title }
        : null
  };
}

export function normalizeCockpitToday(raw: Record<string, unknown>): CockpitToday {
  const sections = pick(raw, 'sections', 'sections');
  const mail = pick(raw, 'mail', 'mail');
  const recent = pick(raw, 'recent_sessions', 'recentSessions');
  return {
    calendar: normalizeCalendarSummary(pick(raw, 'calendar', 'calendar')),
    scheduleNotices: normalizeScheduleNotices(pick(raw, 'schedule_notices', 'scheduleNotices')),
    git: normalizeGitRepoRows(pick(raw, 'git', 'git')),
    sections: (Array.isArray(sections) ? sections : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map(normalizeSection),
    mail: (Array.isArray(mail) ? mail : [])
      .filter((m): m is Record<string, unknown> => typeof m === 'object' && m !== null)
      .map((m) => {
        const unread = pick(m, 'unread', 'unread');
        return {
          account: str(m.account) ?? '',
          configured: m.configured === true,
          state: str(m.state) ?? '',
          pendingOps: num(pick(m, 'pending_ops', 'pendingOps')),
          notices: (Array.isArray(m.notices) ? m.notices : []).filter((n): n is string => typeof n === 'string'),
          unreadCount: num(pick(m, 'unread_count', 'unreadCount')),
          unread: (Array.isArray(unread) ? unread : [])
            .filter((u): u is Record<string, unknown> => typeof u === 'object' && u !== null)
            .flatMap((u) => {
              const msgId = str(pick(u, 'msg_id', 'msgId'));
              if (!msgId) return [];
              return [
                {
                  msgId,
                  fromName: str(pick(u, 'from_name', 'fromName')),
                  fromEmail: str(pick(u, 'from_email', 'fromEmail')),
                  subject: str(u.subject),
                  date: str(u.date)
                }
              ];
            })
        };
      }),
    recentSessions: (Array.isArray(recent) ? recent : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map((s) => ({
        id: str(s.id) ?? '',
        title: str(s.title) ?? '',
        startedAt: str(pick(s, 'started_at', 'startedAt')) ?? '',
        status: str(s.status) ?? '',
        live: s.live === true
      }))
  };
}

/**
 * One notice's sentence. `waiting` is a run parked on a permission ask,
 * `failed` is a run that did not complete, `registered` is a schedule this
 * workspace saw for the first time in the last 24 h.
 */
export function scheduleNoticeText(notice: ScheduleNotice): string {
  switch (notice.kind) {
    case 'waiting':
      return `${notice.title} is waiting for your approval`;
    case 'failed':
      return `${notice.title} failed`;
    case 'registered':
      return `${notice.title} was registered`;
    default:
      return `${notice.title}: ${notice.kind}`;
  }
}

/**
 * Where a notice sends the user: the Schedules tab, always.
 *
 * The spec's own access path for a scheduled session is the run history under
 * its schedule (§Scheduled-session visibility) — and the notice payload carries
 * NO session id (`Valea.Cockpit`'s `notice/4`: kind, mount_key, schedule_id,
 * title, at), so a `waiting` notice could not link a transcript directly even if
 * it wanted to. One destination for all three kinds, where the transcript link,
 * the failure's captured output, and the next fire all already live.
 */
export function scheduleNoticeHref(_notice: ScheduleNotice): string {
  return '/tasks?tab=schedules';
}
