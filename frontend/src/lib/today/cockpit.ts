/**
 * Local shape for the seeded cockpit-today narrative.
 *
 * The backend action returns an unconstrained `:map` (string keys straight
 * from `Valea.Cockpit.today/0`), so AshTypescript generates only
 * `Record<string, any>` and — per its pipeline — passes unconstrained map
 * keys through *unformatted* (snake_case). The normalizer below maps that
 * into a typed camelCase shape, and defensively accepts camelCase keys too
 * in case the payload ever gains a typed schema (which would opt it into
 * the camelCase output formatter).
 */

export type ScheduleItem = {
  time: string;
  title: string;
  subtitle: string;
  status: string | null;
};

export type PreparedItem = {
  type: string;
  title: string;
  summary: string;
  usedSources: string[];
  primaryAction: string;
  secondaryAction?: string;
};

export type OpenLoop = {
  title: string;
  source: string;
};

/**
 * Task 18's live addition to the otherwise-still-seeded payload —
 * `Valea.Cockpit.today/0`'s `"mail"` field (`review_count`/`inbox_count`
 * from `Valea.Mail.Store`, `configured` from `Valea.Mail.Engine.status/0`,
 * all zero/false when no workspace/engine is up). `configured` gates
 * `routes/+page.svelte`'s choice between the single seed
 * `InquiryTriageCard` and one card per real review message.
 */
export type MailSummary = {
  reviewCount: number;
  inboxCount: number;
  configured: boolean;
};

export type CockpitToday = {
  workspace: string;
  dateLabel: string;
  greeting: string;
  summary: string;
  schedule: ScheduleItem[];
  preparedItems: PreparedItem[];
  openLoops: OpenLoop[];
  whileYouWereAway: string[];
  mail: MailSummary;
};

type RawMap = Record<string, any>;

function pick(raw: RawMap, camel: string, snake: string): any {
  return raw[snake] !== undefined ? raw[snake] : raw[camel];
}

function asString(value: unknown): string {
  return typeof value === 'string' ? value : '';
}

function asNumber(value: unknown): number {
  return typeof value === 'number' ? value : 0;
}

function asStringList(value: unknown): string[] {
  return Array.isArray(value) ? value.filter((v): v is string => typeof v === 'string') : [];
}

function normalizeScheduleItem(raw: RawMap): ScheduleItem {
  return {
    time: asString(raw.time),
    title: asString(raw.title),
    subtitle: asString(raw.subtitle),
    status: typeof raw.status === 'string' ? raw.status : null
  };
}

function normalizePreparedItem(raw: RawMap): PreparedItem {
  const secondary = pick(raw, 'secondaryAction', 'secondary_action');
  return {
    type: asString(raw.type),
    title: asString(raw.title),
    summary: asString(raw.summary),
    usedSources: asStringList(pick(raw, 'usedSources', 'used_sources')),
    primaryAction: asString(pick(raw, 'primaryAction', 'primary_action')),
    secondaryAction: typeof secondary === 'string' ? secondary : undefined
  };
}

function normalizeOpenLoop(raw: RawMap): OpenLoop {
  return { title: asString(raw.title), source: asString(raw.source) };
}

function normalizeMailSummary(raw: unknown): MailSummary {
  const rec: RawMap = raw && typeof raw === 'object' ? (raw as RawMap) : {};
  return {
    reviewCount: asNumber(pick(rec, 'reviewCount', 'review_count')),
    inboxCount: asNumber(pick(rec, 'inboxCount', 'inbox_count')),
    configured: pick(rec, 'configured', 'configured') === true
  };
}

export function normalizeCockpitToday(raw: RawMap): CockpitToday {
  const schedule = pick(raw, 'schedule', 'schedule');
  const prepared = pick(raw, 'preparedItems', 'prepared_items');
  const loops = pick(raw, 'openLoops', 'open_loops');
  const away = pick(raw, 'whileYouWereAway', 'while_you_were_away');

  return {
    workspace: asString(raw.workspace),
    dateLabel: asString(pick(raw, 'dateLabel', 'date_label')),
    greeting: asString(raw.greeting),
    summary: asString(raw.summary),
    schedule: Array.isArray(schedule) ? schedule.map(normalizeScheduleItem) : [],
    preparedItems: Array.isArray(prepared) ? prepared.map(normalizePreparedItem) : [],
    openLoops: Array.isArray(loops) ? loops.map(normalizeOpenLoop) : [],
    whileYouWereAway: asStringList(away),
    mail: normalizeMailSummary(raw.mail)
  };
}

/** "N to review · M in inbox" — the mail summary clause `routes/+page.svelte` appends when `mail.configured`. */
export function mailSummaryLine(mail: MailSummary): string {
  return `${mail.reviewCount} to review · ${mail.inboxCount} in inbox`;
}

/**
 * Splits the summary at the trust clause ("nothing has been sent…") so the
 * page can render the clause bold. Returns the whole summary as `lead` when
 * the clause isn't present.
 */
export function splitTrustClause(summary: string): { lead: string; trust: string } {
  const marker = 'nothing has been sent';
  const idx = summary.indexOf(marker);
  if (idx === -1) return { lead: summary, trust: '' };
  return { lead: summary.slice(0, idx), trust: summary.slice(idx) };
}
