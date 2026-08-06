/**
 * The task ledger's display model plus the Tasks tab's Today filter and sort
 * (tasks+schedules spec §UI surfaces → Tasks tab).
 *
 * Entries arrive from `list_tasks` as the FILE's own maps — an unconstrained
 * `{:array, :map}` action field, so keys stay snake_case and unknown keys ride
 * along (`Valea.Api.Tasks`' moduledoc: the leniency contract promises to
 * preserve them). `normalizeTask` reads the fields the UI renders and keeps the
 * raw map beside them; nothing here ever drops or rewrites a key.
 *
 * Lenient display, per the spec: a wrong-typed title/notes/priority/source
 * degrades to `null`, `today` is only ever `true` for a real JSON `true`, and
 * an unknown `status` is preserved verbatim (rendered as text, sorted last by
 * `orderTaskRows`) rather than coerced into one of the four Valea knows.
 */

/** The four statuses `Valea.Tasks` defines — anything else is an unknown status the UI shows as text. */
export const KNOWN_STATUSES = ['open', 'in_progress', 'done', 'dropped'] as const;

/** `done`/`dropped` — the pair `Valea.Cockpit`'s tasks line calls completed, and what "Clear done" archives. */
export const COMPLETED_STATUSES = ['done', 'dropped'] as const;

export type TaskEntry = {
  /** `null` for an id-less entry — not addressable, so it gets the repair affordance instead of row actions. */
  id: string | null;
  title: string | null;
  notes: string | null;
  /** Raw file value (`""` when absent or wrong-typed, which reads as "no status" and sorts with the unknowns). */
  status: string;
  assignee: string | null;
  /** Raw `due` string; only a plain `YYYY-MM-DD` counts as a date (see `dueDate`). */
  due: string | null;
  today: boolean;
  priority: string | null;
  source: string | null;
  createdBy: string | null;
  createdAt: string | null;
  updatedAt: string | null;
  doneAt: string | null;
  /** The entry exactly as read, so an editor round-trips fields Valea doesn't understand. */
  raw: Record<string, unknown>;
};

function str(value: unknown): string | null {
  return typeof value === 'string' ? value : null;
}

export function normalizeTask(raw: Record<string, unknown>): TaskEntry {
  return {
    id: str(raw.id),
    title: str(raw.title),
    notes: str(raw.notes),
    status: str(raw.status) ?? '',
    assignee: str(raw.assignee),
    due: str(raw.due),
    today: raw.today === true,
    priority: str(raw.priority),
    source: str(raw.source),
    createdBy: str(raw.created_by),
    createdAt: str(raw.created_at),
    updatedAt: str(raw.updated_at),
    doneAt: str(raw.done_at),
    raw
  };
}

export function isKnownStatus(status: string): boolean {
  return (KNOWN_STATUSES as readonly string[]).includes(status);
}

export function isCompleted(task: TaskEntry): boolean {
  return (COMPLETED_STATUSES as readonly string[]).includes(task.status);
}

/**
 * The entry's `due` as a plain calendar date, or `null` when it isn't one —
 * the SAME leniency `Valea.Cockpit.tasks_line/2` applies (`Date.from_iso8601`
 * or nothing). Compared as strings throughout: `YYYY-MM-DD` sorts lexically,
 * so no Date object (and no timezone) ever enters the comparison.
 */
export function dueDate(task: TaskEntry): string | null {
  const due = task.due;
  if (due === null || !/^\d{4}-\d{2}-\d{2}$/.test(due)) return null;
  // Rejects "2026-13-40": a well-shaped string that isn't a date.
  const parsed = new Date(`${due}T00:00:00Z`);
  if (Number.isNaN(parsed.getTime())) return null;
  return parsed.toISOString().slice(0, 10) === due ? due : null;
}

/**
 * Local-timezone `YYYY-MM-DD` for a Date — what "today" means to everything
 * above. NOT `toISOString().slice(0, 10)`: that is UTC, and west of Greenwich
 * it reports tomorrow's date all evening (the calendar grid's `dayKey` in
 * `components/calendar/calendar-shapes.ts` mirrors this, for the same reason).
 *
 * The host zone is the right zone here — the backend asks the same question of
 * the same machine (`Valea.Cockpit.tasks_line/2`), so the cockpit line and the
 * tab agree about what is due.
 */
export function localDateIso(date: Date): string {
  const month = String(date.getMonth() + 1).padStart(2, '0');
  const day = String(date.getDate()).padStart(2, '0');
  return `${date.getFullYear()}-${month}-${day}`;
}

export function isOverdue(task: TaskEntry, todayIso: string): boolean {
  const due = dueDate(task);
  return due !== null && due < todayIso;
}

export function isDueToday(task: TaskEntry, todayIso: string): boolean {
  return dueDate(task) === todayIso;
}

/**
 * The spec's default filter: due today + overdue + the `today` flag +
 * `in_progress`, whatever the due date. Completed entries (`done`/`dropped`)
 * are excluded — Today is the day's OPEN work, the same reading
 * `Valea.Cockpit.tasks_line/2` takes when it counts the cockpit line; the All
 * filter is where a finished task stays visible until "Clear done" archives it.
 */
export function todayFilter(tasks: TaskEntry[], todayIso: string): TaskEntry[] {
  return tasks.filter((task) => {
    if (isCompleted(task)) return false;
    return task.today || task.status === 'in_progress' || isDueToday(task, todayIso) || isOverdue(task, todayIso);
  });
}

const PRIORITY_RANK: Record<string, number> = { high: 0, medium: 1, low: 2 };

function priorityRank(task: TaskEntry): number {
  return task.priority !== null && task.priority in PRIORITY_RANK ? PRIORITY_RANK[task.priority] : 3;
}

/**
 * Pinned order (spec §Cockpit, and the same keys `Valea.Cockpit`'s
 * `top_tasks/1` sorts by so the cockpit's top items and the tab's rows agree):
 * `today`-flag first, then due ascending (an entry with no parseable due sorts
 * after every dated one), then priority high > medium > low > anything else,
 * then `created_at` ascending (a missing stamp sorts last — it says nothing
 * about age, and inventing "oldest" for it would reorder rows on every write).
 *
 * Stable: `Array.prototype.sort` is stable per spec, so entries equal on all
 * four keys keep their FILE order — which is what makes "first occurrence
 * wins" (duplicate ids) mean something the user can see.
 */
export function sortTasks(tasks: TaskEntry[]): TaskEntry[] {
  return [...tasks].sort((a, b) => {
    const todayDelta = (a.today ? 0 : 1) - (b.today ? 0 : 1);
    if (todayDelta !== 0) return todayDelta;

    const dueA = dueDate(a);
    const dueB = dueDate(b);
    if (dueA !== dueB) {
      if (dueA === null) return 1;
      if (dueB === null) return -1;
      return dueA < dueB ? -1 : 1;
    }

    const priorityDelta = priorityRank(a) - priorityRank(b);
    if (priorityDelta !== 0) return priorityDelta;

    const createdA = a.createdAt ?? '';
    const createdB = b.createdAt ?? '';
    if (createdA === createdB) return 0;
    if (createdA === '') return 1;
    if (createdB === '') return -1;
    return createdA < createdB ? -1 : 1;
  });
}

/**
 * `sortTasks` with the spec's one extra rule for degenerate entries: "unknown
 * statuses render as text and sort last". Kept OUT of `sortTasks` so that
 * function stays exactly the four pinned keys — this is a display partition
 * (two `sortTasks` runs concatenated), not a fifth sort key.
 */
export function orderTaskRows(tasks: TaskEntry[]): TaskEntry[] {
  const known = tasks.filter((task) => isKnownStatus(task.status));
  const unknown = tasks.filter((task) => !isKnownStatus(task.status));
  return [...sortTasks(known), ...sortTasks(unknown)];
}

export type TaskFilter = 'today' | 'all';

/** Filter chip state the Tasks tab holds: the Today/All view plus optional assignee and status narrowing. */
export type TaskFilters = {
  view: TaskFilter;
  /** `null` = any assignee. */
  assignee: string | null;
  /** `null` = any status. */
  status: string | null;
};

export const DEFAULT_TASK_FILTERS: TaskFilters = { view: 'today', assignee: null, status: null };

/**
 * Applies the tab's whole filter set, then `orderTaskRows`. The assignee and
 * status chips narrow WITHIN the chosen view (an explicit status chip can
 * therefore surface `done` entries while the view is Today — the user asked
 * for that status by name).
 */
export function applyTaskFilters(tasks: TaskEntry[], filters: TaskFilters, todayIso: string): TaskEntry[] {
  const base = filters.view === 'today' ? todayFilter(tasks, todayIso) : tasks;
  const narrowed = base.filter((task) => {
    if (filters.assignee !== null && (task.assignee ?? 'user') !== filters.assignee) return false;
    if (filters.status !== null && task.status !== filters.status) return false;
    return true;
  });
  return orderTaskRows(narrowed);
}

/**
 * A status chip's own count, computed against the view the chips narrow — so
 * "· 3" on the chip always matches the rows a click produces.
 */
export function countByStatus(tasks: TaskEntry[], status: string): number {
  return tasks.filter((task) => task.status === status).length;
}

// -- redesign additions (spec 2026-08-06) -------------------------------------

/** `iso + days` in pure string-date math (UTC-anchored, so no DST wobble). */
export function addDaysIso(iso: string, days: number): string {
  const d = new Date(`${iso}T00:00:00Z`);
  d.setUTCDate(d.getUTCDate() + days);
  return d.toISOString().slice(0, 10);
}

/** Whole days a task is overdue, or null when it isn't (no/invalid/future due). */
export function overdueDays(task: TaskEntry, todayIso: string): number | null {
  const due = dueDate(task);
  if (due === null || due >= todayIso) return null;
  const ms = Date.parse(`${todayIso}T00:00:00Z`) - Date.parse(`${due}T00:00:00Z`);
  return Math.round(ms / 86_400_000);
}

export function overduePillText(days: number): string {
  return days === 1 ? '1 day over' : `${days} days over`;
}

export type PriorityGlyphSpec = { glyph: '‼' | '!' | '·'; tone: 'high' | 'medium' | 'low' };

/**
 * The word became a glyph (spec §List rows). Unknown priorities return null —
 * they keep their verbatim text chip (leniency), a glyph would launder them.
 */
export function priorityGlyph(priority: string | null): PriorityGlyphSpec | null {
  if (priority === 'high') return { glyph: '‼', tone: 'high' };
  if (priority === 'medium') return { glyph: '!', tone: 'medium' };
  if (priority === 'low') return { glyph: '·', tone: 'low' };
  return null;
}

/** Case-insensitive substring over title + notes. Blank query matches everything (search is narrowing, not a view). */
export function matchesSearch(task: TaskEntry, query: string): boolean {
  const q = query.trim().toLowerCase();
  if (q === '') return true;
  return (task.title ?? '').toLowerCase().includes(q) || (task.notes ?? '').toLowerCase().includes(q);
}

export type DueBucket = 'overdue' | 'today' | 'week' | 'later' | 'none';

/** "This week" = within the next 7 days inclusive. No/invalid due → 'none'. */
export function dueBucket(task: TaskEntry, todayIso: string): DueBucket {
  const due = dueDate(task);
  if (due === null) return 'none';
  if (due < todayIso) return 'overdue';
  if (due === todayIso) return 'today';
  if (due <= addDaysIso(todayIso, 7)) return 'week';
  return 'later';
}

export type TaskGroup = { key: string; label: string; rows: TaskEntry[] };

const PRIORITY_GROUPS: { key: string; label: string; match: (p: string | null) => boolean }[] = [
  { key: 'high', label: 'High', match: (p) => p === 'high' },
  { key: 'medium', label: 'Medium', match: (p) => p === 'medium' },
  { key: 'low', label: 'Low', match: (p) => p === 'low' },
  { key: 'none', label: 'None', match: (p) => p === null || !['high', 'medium', 'low'].includes(p) }
];

/** High/Medium/Low/None in that order; unknown priorities join None; empty buckets dropped. Rows keep incoming order. */
export function groupByPriority(rows: TaskEntry[]): TaskGroup[] {
  return PRIORITY_GROUPS.map(({ key, label, match }) => ({
    key,
    label,
    rows: rows.filter((row) => match(row.priority))
  })).filter((group) => group.rows.length > 0);
}

const DUE_LABELS: Record<DueBucket, string> = {
  overdue: 'Overdue',
  today: 'Today',
  week: 'This week',
  later: 'Later',
  none: 'No date'
};

export function groupByDue(rows: TaskEntry[], todayIso: string): TaskGroup[] {
  return (['overdue', 'today', 'week', 'later', 'none'] as DueBucket[])
    .map((key) => ({ key, label: DUE_LABELS[key], rows: rows.filter((row) => dueBucket(row, todayIso) === key) }))
    .filter((group) => group.rows.length > 0);
}

/** Overdue rows split out and re-sorted oldest-due-first (the warn group); the rest keep incoming order. */
export function splitOverdue(rows: TaskEntry[], todayIso: string): { overdue: TaskEntry[]; rest: TaskEntry[] } {
  const overdue = rows
    .filter((row) => overdueDays(row, todayIso) !== null)
    .sort((a, b) => (dueDate(a)! < dueDate(b)! ? -1 : dueDate(a)! > dueDate(b)! ? 1 : 0));
  return { overdue, rest: rows.filter((row) => overdueDays(row, todayIso) === null) };
}

/**
 * The empty-Today "Next up" picker: open backlog (outside the today view),
 * standard sort, capped.
 *
 * The today rows are excluded by OBJECT IDENTITY, never by `id`: `id` is
 * nullable and duplicable (the leniency contract renders both), so an id-keyed
 * set answered `has(null)` for every id-less backlog entry the moment one
 * id-less row was flagged for today — and the whole id-less backlog vanished.
 * `todayFilter` returns the very references it was handed, so identity is exact.
 */
export function nextUp(tasks: TaskEntry[], todayIso: string, limit: number): TaskEntry[] {
  const today = new Set(todayFilter(tasks, todayIso));
  return sortTasks(tasks.filter((task) => !isCompleted(task) && !today.has(task))).slice(0, limit);
}
