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
export type MailSummary = { reviewCount: number; inboxCount: number; configured: boolean };
export type CockpitToday = {
  sections: TodaySection[];
  mail: MailSummary;
  recentSessions: RecentSession[];
};

function str(v: unknown): string | null {
  return typeof v === 'string' ? v : null;
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

export function normalizeCockpitToday(raw: Record<string, unknown>): CockpitToday {
  const sections = pick(raw, 'sections', 'sections');
  const mail = (pick(raw, 'mail', 'mail') ?? {}) as Record<string, unknown>;
  const recent = pick(raw, 'recent_sessions', 'recentSessions');
  return {
    sections: (Array.isArray(sections) ? sections : [])
      .filter((s): s is Record<string, unknown> => typeof s === 'object' && s !== null)
      .map(normalizeSection),
    mail: {
      reviewCount: Number(pick(mail, 'review_count', 'reviewCount') ?? 0),
      inboxCount: Number(pick(mail, 'inbox_count', 'inboxCount') ?? 0),
      configured: pick(mail, 'configured', 'configured') === true
    },
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
 * "N to review · M in inbox" — the mail summary clause `routes/+page.svelte`
 * appends when `mail.configured`. Carried over from the pre-Spec-D revision
 * of this module (still has a consumer there); ported onto the new
 * `MailSummary` shape above, which is structurally identical.
 */
export function mailSummaryLine(mail: MailSummary): string {
  return `${mail.reviewCount} to review · ${mail.inboxCount} in inbox`;
}
