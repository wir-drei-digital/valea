/**
 * Types + normalizer for the Spec-D cockpit payload (`cockpit_today` RPC):
 * per-ICM sections read from `today.json` files agents maintain, plus the
 * live state Valea owns (mail counts, recent sessions). The normalizer
 * accepts BOTH snake_case and camelCase keys, same defensive stance the
 * previous revision took toward the generic-action map boundary.
 */
export type TodayPrepared = { title: string | null; summary: string | null; page: string | null };
export type TodayOpenLoop = { title: string | null; source: string | null };
export type TodaySection = {
  mountKey: string;
  icmName: string;
  ok: boolean;
  updatedAt: string | null;
  notes: string | null;
  prepared: TodayPrepared[];
  openLoops: TodayOpenLoop[];
};
export type RecentSession = {
  id: string;
  title: string;
  startedAt: string;
  status: string;
  live: boolean;
};
/** One configured account's cockpit line (`Valea.Cockpit.mail_summary/0` — per-account since the mail-as-maildir rework). */
export type MailAccountSummary = {
  account: string;
  configured: boolean;
  state: string;
  pendingOps: number;
  notices: string[];
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

function normalizeSection(raw: Record<string, unknown>): TodaySection {
  const prepared = Array.isArray(raw.prepared) ? raw.prepared : [];
  const openLoops = pick(raw, 'open_loops', 'openLoops');
  return {
    mountKey: str(pick(raw, 'mount_key', 'mountKey')) ?? '',
    icmName: str(pick(raw, 'icm_name', 'icmName')) ?? '',
    ok: pick(raw, 'ok', 'ok') === true,
    updatedAt: str(pick(raw, 'updated_at', 'updatedAt')),
    notes: str(raw.notes),
    prepared: prepared
      .filter((p): p is Record<string, unknown> => typeof p === 'object' && p !== null)
      .map((p) => ({ title: str(p.title), summary: str(p.summary), page: str(p.page) })),
    openLoops: (Array.isArray(openLoops) ? openLoops : [])
      .filter((l): l is Record<string, unknown> => typeof l === 'object' && l !== null)
      .map((l) => ({ title: str(l.title), source: str(l.source) }))
  };
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
    sections: (Array.isArray(sections) ? sections : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map(normalizeSection),
    mail: (Array.isArray(mail) ? mail : [])
      .filter((m): m is Record<string, unknown> => typeof m === 'object' && m !== null)
      .map((m) => ({
        account: str(m.account) ?? '',
        configured: m.configured === true,
        state: str(m.state) ?? '',
        pendingOps: num(pick(m, 'pending_ops', 'pendingOps')),
        notices: (Array.isArray(m.notices) ? m.notices : []).filter((n): n is string => typeof n === 'string')
      })),
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
 * "work: idle · 2 pending" — one configured account's summary line for the
 * Today header (`routes/+page.svelte` renders one per configured account).
 */
export function mailSummaryLine(mail: MailAccountSummary): string {
  return `${mail.account}: ${mail.state} · ${mail.pendingOps} pending`;
}

/** Spec F's Today-page calendar line: "3 events today · next: 09:30 Coffee with Priya" (no next → count only). */
export function calendarSummaryLine(calendar: CalendarSummary): string {
  const count = `${calendar.eventsToday} ${calendar.eventsToday === 1 ? 'event' : 'events'} today`;
  return calendar.next ? `${count} · next: ${calendar.next.time} ${calendar.next.title}` : count;
}
