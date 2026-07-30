/**
 * Human-readable cadence for a cron expression — the Schedules tab's row
 * label ("weekdays 07:30" for `30 7 * * 1-5`, tasks+schedules spec §UI
 * surfaces).
 *
 * Deliberately a RENDERER, not a parser: `Valea.Schedules.Cron` owns the
 * grammar and decides what fires (strict execution), and the row already shows
 * the entry's own `disposition`/`reason` when it doesn't. This function only
 * recognizes the handful of shapes a person writes on purpose and falls back to
 * **the raw expression verbatim** for everything else — a wrong-but-confident
 * phrasing of an exotic expression would be worse than the expression itself.
 *
 * Table-driven: each rule is a predicate over the five parsed fields plus a
 * phrasing, tried in order. Adding a shape means adding a row, never editing a
 * branch.
 */

/** `@hourly`-style aliases the backend accepts (`Valea.Schedules.Cron`), expanded before any rule runs. */
const ALIASES: Record<string, string> = {
  '@hourly': '0 * * * *',
  '@daily': '0 0 * * *',
  '@midnight': '0 0 * * *',
  '@weekly': '0 0 * * 0',
  '@monthly': '0 0 1 * *'
};

const DAY_NAMES = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const DAY_SHORT = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

type Fields = { minute: string; hour: string; dom: string; month: string; dow: string };

function fieldsOf(expr: string): Fields | null {
  const parts = expr.trim().split(/\s+/);
  if (parts.length !== 5) return null;
  const [minute, hour, dom, month, dow] = parts;
  return { minute, hour, dom, month, dow };
}

/** A single numeric value in `0..max`, or `null` — leading zeros allowed (`07`), signs and ranges are not. */
function single(field: string, max: number): number | null {
  if (!/^\d{1,2}$/.test(field)) return null;
  const value = Number(field);
  return value <= max ? value : null;
}

/** A comma list of single day numbers (`1,3,5`), normalized to `0..6` with Sunday as both 0 and 7. */
function dayList(field: string): number[] | null {
  const parts = field.split(',');
  const days: number[] = [];
  for (const part of parts) {
    const value = single(part, 7);
    if (value === null) return null;
    days.push(value === 7 ? 0 : value);
  }
  return days.length > 0 ? days : null;
}

function pad(value: number): string {
  return String(value).padStart(2, '0');
}

/** "07:30" from the minute/hour fields, or `null` when either isn't a single value. */
function clock(fields: Fields): string | null {
  const minute = single(fields.minute, 59);
  const hour = single(fields.hour, 23);
  if (minute === null || hour === null) return null;
  return `${pad(hour)}:${pad(minute)}`;
}

type Rule = { render: (fields: Fields) => string | null };

// Order matters: the first rule that renders wins, so the specific shapes
// (weekdays, a named day) come before the general daily one.
const RULES: Rule[] = [
  // `*/15 * * * *` — the one step shape worth phrasing; sub-hour cadences are
  // the common "poll something" case.
  {
    render: ({ minute, hour, dom, month, dow }) => {
      if (hour !== '*' || dom !== '*' || month !== '*' || dow !== '*') return null;
      const match = /^\*\/(\d{1,2})$/.exec(minute);
      if (!match) return null;
      const step = Number(match[1]);
      if (step < 1 || step > 59) return null;
      return step === 1 ? 'every minute' : `every ${step} minutes`;
    }
  },
  // `0 * * * *` → "hourly at :00".
  {
    render: ({ minute, hour, dom, month, dow }) => {
      if (hour !== '*' || dom !== '*' || month !== '*' || dow !== '*') return null;
      const value = single(minute, 59);
      return value === null ? null : `hourly at :${pad(value)}`;
    }
  },
  // `30 7 * * 1-5` → "weekdays 07:30". Only this exact range: `2-6` is not the
  // work week anywhere, and phrasing it as one would be a lie.
  {
    render: (fields) => {
      if (fields.dom !== '*' || fields.month !== '*' || fields.dow !== '1-5') return null;
      const time = clock(fields);
      return time === null ? null : `weekdays ${time}`;
    }
  },
  // `0 9 * * 6,0` → "weekends 09:00" (either spelling of Sunday).
  {
    render: (fields) => {
      if (fields.dom !== '*' || fields.month !== '*') return null;
      const days = dayList(fields.dow);
      if (days === null || days.length !== 2) return null;
      const set = new Set(days);
      if (!(set.has(0) && set.has(6))) return null;
      const time = clock(fields);
      return time === null ? null : `weekends ${time}`;
    }
  },
  // `0 9 * * 1` → "Mondays 09:00"; `0 9 * * 1,3,5` → "Mon, Wed, Fri 09:00".
  {
    render: (fields) => {
      if (fields.dom !== '*' || fields.month !== '*' || fields.dow === '*') return null;
      const days = dayList(fields.dow);
      if (days === null) return null;
      const time = clock(fields);
      if (time === null) return null;
      const unique = [...new Set(days)].sort((a, b) => a - b);
      if (unique.length === 1) return `${DAY_NAMES[unique[0]]}s ${time}`;
      return `${unique.map((day) => DAY_SHORT[day]).join(', ')} ${time}`;
    }
  },
  // `0 6 1 * *` → "monthly on day 1, 06:00".
  {
    render: (fields) => {
      if (fields.month !== '*' || fields.dow !== '*') return null;
      const day = single(fields.dom, 31);
      if (day === null || day < 1) return null;
      const time = clock(fields);
      return time === null ? null : `monthly on day ${day}, ${time}`;
    }
  },
  // `30 7 * * *` → "daily 07:30".
  {
    render: (fields) => {
      if (fields.dom !== '*' || fields.month !== '*' || fields.dow !== '*') return null;
      const time = clock(fields);
      return time === null ? null : `daily ${time}`;
    }
  }
];

/**
 * The cadence phrase for `expr`, or `expr` itself (trimmed) when no rule
 * recognizes it. Never throws and never returns an empty string for a
 * non-empty input.
 */
export function humanizeCron(expr: string): string {
  const trimmed = expr.trim();
  const expanded = ALIASES[trimmed.toLowerCase()] ?? trimmed;
  const fields = fieldsOf(expanded);
  if (fields === null) return trimmed;

  for (const rule of RULES) {
    const rendered = rule.render(fields);
    if (rendered !== null) return rendered;
  }

  return trimmed;
}
