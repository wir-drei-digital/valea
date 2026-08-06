# Today & Tasks Redesign Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Rebuild the Today page as an actionable cockpit (editorial column + rail) and the Tasks page as a dense list + status board, with hand-to-assistant, day planning, search/group, persisted filters, and prominent overdue treatment.

**Architecture:** Pure display/filter decisions live in tested TypeScript modules (`lib/tasks/*`, `lib/today/*`); Svelte components stay markup + event wiring (the repo has no component render harness). One backend change: `Valea.Cockpit` emits a section for every enabled ICM with a `today_json` state string. Task mutations ride the existing `list_tasks`/`mutate_task` RPC surface; hand-off rides `create_agent_session` + the initial-prompt handoff.

**Tech Stack:** Svelte 5 (runes), SvelteKit SPA, Tailwind 4 tokens, shadcn-svelte/bits-ui, Phoenix + Ash RPC, Vitest (unit + runes projects), ExUnit.

**Spec:** `docs/superpowers/specs/2026-08-06-today-tasks-redesign-design.md` — binding. Where this plan and the spec disagree, stop and ask.

## Global Constraints

- NEVER run `prettier` bare on `frontend/` (no config — it would reformat the repo). No new formatter runs at all.
- Frontend tests run FROM `frontend/`: `npx vitest run` (all), `npx vitest run <path>` (one file). Never from repo root.
- Runes tests are `*.test.svelte.ts` (the `runes` vitest project picks them by filename — do NOT add `@vitest-environment` headers). Plain logic tests are `*.test.ts`.
- Backend tests run from `backend/`: `mix test <path>`. A `mix format` hook runs on backend commits; do not fight it.
- After ANY change to RPC fields/actions: `cd backend && mix ash_typescript.codegen` then `mix ash_typescript.codegen --check` must pass; commit the regenerated file with the change.
- Colour reaches components through tokens only — `warn-ink`, `warn-tint`, `warn-border`, `warn-dot`, `act`, `ink-*`, `paper-*`. No hex literals in components.
- Leniency contract: unknown statuses/priorities render verbatim, malformed data degrades calmly, unknown keys in `tasks.json` entries are never dropped (`raw` round-trips).
- Storage keys, verbatim: `valea.tasks.filters` and `valea.today.assignee`. localStorage access ONLY through `lib/persist.ts` (try/catch IS the guard — Node 25 defines a `localStorage` global with undefined methods; `typeof` checks are not the guard).
- Count honesty: a control that shows a count must show exactly the rows its click produces (counts ignore transient search text).
- §11 grammar: section headers are overlines, never boxed; the ONLY new boxed surfaces are the attention card, agent briefing cards, and rail cards.
- No new dependencies (npm or hex). Board drag is native HTML5 DnD.
- Svelte 5 runes; store write paths that read their own `$state` use `untrack` (the `theme.svelte.ts` precedent).
- All copy strings in this plan are exact — use them verbatim.

## File Structure

```
frontend/src/lib/persist.ts                        NEW  guarded JSON localStorage
frontend/src/lib/tasks/settings.ts                 NEW  filter-settings codec (pure)
frontend/src/lib/tasks/settings.svelte.ts          NEW  persisted settings store
frontend/src/lib/tasks/filters.ts                  MOD  overdue/glyph/search/group/next-up maths
frontend/src/lib/tasks/board.ts                    NEW  board column model (pure)
frontend/src/lib/tasks/handoff.ts                  NEW  hand-off prompt + session-live lookup (pure)
frontend/src/lib/today/greeting.ts                 NEW  greeting, date overline, summary segments (pure)
frontend/src/lib/today/today-view.ts               NEW  tail-line segments, rail row shaping (pure)
frontend/src/lib/today/cockpit.ts                  MOD  todayJson state on sections
frontend/src/lib/components/tasks/task-shapes.ts   MOD  basename source labels, session key read
frontend/src/lib/components/tasks/OverduePill.svelte    NEW
frontend/src/lib/components/tasks/PriorityGlyph.svelte  NEW
frontend/src/lib/components/tasks/TaskRow.svelte   MOD  single-line density pass
frontend/src/lib/components/tasks/TasksTab.svelte  MOD  controls/group/fold/next-up rework
frontend/src/lib/components/tasks/QuickAdd.svelte  MOD  inline first-row styling
frontend/src/lib/components/tasks/TaskBoard.svelte NEW  board view (columns, DnD)
frontend/src/lib/components/tasks/BoardColumn.svelte NEW
frontend/src/lib/components/tasks/TaskCard.svelte  NEW
frontend/src/lib/components/tasks/SchedulesTab.svelte MOD ordering fixes only
frontend/src/lib/components/today/AttentionCard.svelte  NEW
frontend/src/lib/components/today/AgentBriefingCard.svelte NEW
frontend/src/lib/components/today/TodayTasks.svelte NEW
frontend/src/lib/components/today/AgendaSection.svelte NEW
frontend/src/lib/components/today/RailCard.svelte  NEW
frontend/src/routes/+page.svelte                   MOD  Today rebuild
frontend/src/routes/tasks/+page.svelte             MOD  width, persisted store wiring
frontend/src/lib/design/contrast.test.ts           MOD  warn-ink/warn-tint invariant
backend/lib/valea/cockpit.ex                       MOD  sections for every ICM
docs/DESIGN_SYSTEM.md                              MOD  layout/rail/board/overdue notes
```

---

### Task 1: Persistence guard + task filter maths

**Files:**
- Create: `frontend/src/lib/persist.ts`
- Create: `frontend/src/lib/tasks/settings.ts`
- Modify: `frontend/src/lib/tasks/filters.ts` (append; do not reorder existing exports)
- Test: `frontend/src/lib/persist.test.ts`, `frontend/src/lib/tasks/settings.test.ts`, extend `frontend/src/lib/tasks/filters.test.ts` — NOTE: the existing filter tests live at `frontend/src/lib/components/tasks/task-shapes.test.ts` and `frontend/src/lib/tasks/` — check `ls frontend/src/lib/tasks/` first; if `filters.test.ts` does not exist there, create it.

**Interfaces:**
- Consumes: `TaskEntry`, `todayFilter`, `sortTasks`, `dueDate`, `isCompleted`, `isKnownStatus` from `lib/tasks/filters.ts` (existing).
- Produces (later tasks rely on these exact names):
  - `persist.ts`: `readJson(key: string): unknown` (null on any failure), `writeJson(key: string, value: unknown): void` (silent on failure).
  - `settings.ts`: `type TasksViewMode = 'list' | 'board'`; `type TasksGroupBy = 'project' | 'priority' | 'due'`; `type TasksFilterSettings = { mode: TasksViewMode; view: TaskFilter; assignee: 'user' | 'agent' | null; groupBy: TasksGroupBy }`; `DEFAULT_TASKS_FILTER_SETTINGS`; `TASKS_FILTERS_KEY = 'valea.tasks.filters'`; `TODAY_ASSIGNEE_KEY = 'valea.today.assignee'`; `decodeTasksFilterSettings(raw: unknown): TasksFilterSettings`; `decodeTodayAssignee(raw: unknown): 'user' | null`.
  - `filters.ts`: `addDaysIso(iso: string, days: number): string`; `overdueDays(task: TaskEntry, todayIso: string): number | null`; `overduePillText(days: number): string`; `type PriorityGlyphSpec = { glyph: '‼' | '!' | '·'; tone: 'high' | 'medium' | 'low' }`; `priorityGlyph(priority: string | null): PriorityGlyphSpec | null`; `matchesSearch(task: TaskEntry, query: string): boolean`; `type DueBucket = 'overdue' | 'today' | 'week' | 'later' | 'none'`; `dueBucket(task: TaskEntry, todayIso: string): DueBucket`; `type TaskGroup = { key: string; label: string; rows: TaskEntry[] }`; `groupByPriority(rows: TaskEntry[]): TaskGroup[]`; `groupByDue(rows: TaskEntry[], todayIso: string): TaskGroup[]`; `splitOverdue(rows: TaskEntry[], todayIso: string): { overdue: TaskEntry[]; rest: TaskEntry[] }`; `nextUp(tasks: TaskEntry[], todayIso: string, limit: number): TaskEntry[]`.

- [ ] **Step 1: Write the failing tests**

`frontend/src/lib/persist.test.ts`:

```ts
import { describe, expect, it, beforeEach, vi, afterEach } from 'vitest';
import { readJson, writeJson } from './persist';

// Node 25 defines a global `localStorage` whose methods are undefined — the
// module must survive BOTH a missing localStorage and a broken one. try/catch
// is the guard (Global Constraints).
describe('persist', () => {
  afterEach(() => vi.unstubAllGlobals());

  it('round-trips JSON through a working localStorage', () => {
    const store = new Map<string, string>();
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: (k: string, v: string) => void store.set(k, v)
    });
    writeJson('k', { a: 1 });
    expect(readJson('k')).toEqual({ a: 1 });
  });

  it('readJson returns null for absent keys, malformed JSON, and a broken localStorage', () => {
    const store = new Map<string, string>([['bad', '{not json']]);
    vi.stubGlobal('localStorage', {
      getItem: (k: string) => store.get(k) ?? null,
      setItem: () => {}
    });
    expect(readJson('missing')).toBeNull();
    expect(readJson('bad')).toBeNull();
    vi.stubGlobal('localStorage', { getItem: undefined, setItem: undefined });
    expect(readJson('k')).toBeNull();
    expect(() => writeJson('k', 1)).not.toThrow();
  });
});
```

`frontend/src/lib/tasks/settings.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import {
  DEFAULT_TASKS_FILTER_SETTINGS,
  decodeTasksFilterSettings,
  decodeTodayAssignee
} from './settings';

describe('decodeTasksFilterSettings', () => {
  it('accepts a full valid record', () => {
    expect(
      decodeTasksFilterSettings({ mode: 'board', view: 'all', assignee: 'agent', groupBy: 'due' })
    ).toEqual({ mode: 'board', view: 'all', assignee: 'agent', groupBy: 'due' });
  });

  it('degrades FIELD-WISE: unknown values fall back alone, valid neighbours survive', () => {
    expect(
      decodeTasksFilterSettings({ mode: 'kanban', view: 'all', assignee: 'boss', groupBy: 'due' })
    ).toEqual({ mode: 'list', view: 'all', assignee: null, groupBy: 'due' });
  });

  it('returns defaults for null, arrays, strings', () => {
    for (const raw of [null, undefined, [], 'x', 42]) {
      expect(decodeTasksFilterSettings(raw)).toEqual(DEFAULT_TASKS_FILTER_SETTINGS);
    }
  });

  it('assignee null is a VALID stored value, not a fallback marker', () => {
    expect(decodeTasksFilterSettings({ assignee: null }).assignee).toBeNull();
    expect(decodeTasksFilterSettings({ assignee: 'user' }).assignee).toBe('user');
  });
});

describe('decodeTodayAssignee', () => {
  it("only the literal 'user' narrows; everything else is null (Everyone)", () => {
    expect(decodeTodayAssignee('user')).toBe('user');
    for (const raw of [null, 'agent', 'boss', 1, {}]) expect(decodeTodayAssignee(raw)).toBeNull();
  });
});
```

Append to the filters test file (create `frontend/src/lib/tasks/filters.test.ts` if absent, importing from `./filters`):

```ts
import { describe, expect, it } from 'vitest';
import {
  addDaysIso,
  dueBucket,
  groupByDue,
  groupByPriority,
  matchesSearch,
  nextUp,
  overdueDays,
  overduePillText,
  priorityGlyph,
  splitOverdue,
  normalizeTask
} from './filters';

const t = (raw: Record<string, unknown>) => normalizeTask({ id: 'x', title: 't', ...raw });
const TODAY = '2026-08-06';

describe('overdue maths', () => {
  it('counts days over, string-date math, month boundary', () => {
    expect(overdueDays(t({ due: '2026-08-04' }), TODAY)).toBe(2);
    expect(overdueDays(t({ due: '2026-07-31' }), '2026-08-01')).toBe(1);
  });
  it('null for today, future, unparseable, and completed-irrelevant absent due', () => {
    expect(overdueDays(t({ due: TODAY }), TODAY)).toBeNull();
    expect(overdueDays(t({ due: '2026-08-08' }), TODAY)).toBeNull();
    expect(overdueDays(t({ due: 'soonish' }), TODAY)).toBeNull();
    expect(overdueDays(t({}), TODAY)).toBeNull();
  });
  it('pill text singular/plural', () => {
    expect(overduePillText(1)).toBe('1 day over');
    expect(overduePillText(3)).toBe('3 days over');
  });
  it('addDaysIso crosses months and years', () => {
    expect(addDaysIso('2026-08-30', 7)).toBe('2026-09-06');
    expect(addDaysIso('2026-12-28', 7)).toBe('2027-01-04');
  });
});

describe('priorityGlyph', () => {
  it('maps the three known priorities and returns null otherwise', () => {
    expect(priorityGlyph('high')).toEqual({ glyph: '‼', tone: 'high' });
    expect(priorityGlyph('medium')).toEqual({ glyph: '!', tone: 'medium' });
    expect(priorityGlyph('low')).toEqual({ glyph: '·', tone: 'low' });
    expect(priorityGlyph(null)).toBeNull();
    expect(priorityGlyph('urgent')).toBeNull(); // unknown → text chip elsewhere, not a glyph
  });
});

describe('matchesSearch', () => {
  it('case-insensitive substring over title and notes; blank query matches all', () => {
    const task = t({ title: 'Rechnung Kita', notes: 'CHF 500 offen' });
    expect(matchesSearch(task, 'kita')).toBe(true);
    expect(matchesSearch(task, 'chf')).toBe(true);
    expect(matchesSearch(task, 'zzz')).toBe(false);
    expect(matchesSearch(task, '  ')).toBe(true);
    expect(matchesSearch(t({ title: null, notes: null }), 'x')).toBe(false);
  });
});

describe('dueBucket / groupByDue', () => {
  it('buckets overdue/today/week/later/none', () => {
    expect(dueBucket(t({ due: '2026-08-01' }), TODAY)).toBe('overdue');
    expect(dueBucket(t({ due: TODAY }), TODAY)).toBe('today');
    expect(dueBucket(t({ due: '2026-08-13' }), TODAY)).toBe('week'); // today+7 inclusive
    expect(dueBucket(t({ due: '2026-08-14' }), TODAY)).toBe('later');
    expect(dueBucket(t({}), TODAY)).toBe('none');
    expect(dueBucket(t({ due: 'nope' }), TODAY)).toBe('none');
  });
  it('groupByDue emits only non-empty buckets, Overdue first, labeled', () => {
    const rows = [t({ id: 'a', due: '2026-08-20' }), t({ id: 'b', due: '2026-08-01' })];
    const groups = groupByDue(rows, TODAY);
    expect(groups.map((g) => g.key)).toEqual(['overdue', 'later']);
    expect(groups[0].label).toBe('Overdue');
    expect(groups.find((g) => g.key === 'later')!.label).toBe('Later');
  });
});

describe('groupByPriority', () => {
  it('High/Medium/Low/None order, unknown priorities join None, empty buckets dropped', () => {
    const rows = [t({ id: 'a', priority: 'low' }), t({ id: 'b', priority: 'urgent' }), t({ id: 'c', priority: 'high' })];
    const groups = groupByPriority(rows);
    expect(groups.map((g) => g.label)).toEqual(['High', 'Low', 'None']);
    expect(groups[2].rows.map((r) => r.id)).toEqual(['b']);
  });
});

describe('splitOverdue', () => {
  it('overdue oldest-due first; rest keeps incoming order', () => {
    const rows = [
      t({ id: 'later', due: '2026-08-09' }),
      t({ id: 'worse', due: '2026-08-01' }),
      t({ id: 'bad', due: '2026-08-04' })
    ];
    const { overdue, rest } = splitOverdue(rows, TODAY);
    expect(overdue.map((r) => r.id)).toEqual(['worse', 'bad']);
    expect(rest.map((r) => r.id)).toEqual(['later']);
  });
});

describe('nextUp', () => {
  it('open backlog only (not today-view, not completed), standard sort, capped', () => {
    const rows = [
      t({ id: 'in-today', today: true }),
      t({ id: 'done', status: 'done' }),
      t({ id: 'p-high', priority: 'high' }),
      t({ id: 'p-low', priority: 'low' }),
      t({ id: 'dated', due: '2026-09-01' })
    ];
    expect(nextUp(rows, TODAY, 2).map((r) => r.id)).toEqual(['dated', 'p-high']);
  });
});
```

- [ ] **Step 2: Run the new tests, verify they fail** — `cd frontend && npx vitest run src/lib/persist.test.ts src/lib/tasks/settings.test.ts src/lib/tasks/filters.test.ts`. Expected: module-not-found / export-missing failures.

- [ ] **Step 3: Implement**

`frontend/src/lib/persist.ts`:

```ts
/**
 * Guarded localStorage JSON — the ONE place storage is touched (Global
 * Constraints). try/catch is the real guard: Node 25 ships a global
 * `localStorage` whose methods are undefined, so feature-detection by
 * `typeof` lies. Failures read as null / write as no-op; persistence is an
 * enhancement, never a dependency.
 */
export function readJson(key: string): unknown {
  try {
    const raw = localStorage.getItem(key);
    return raw === null ? null : JSON.parse(raw);
  } catch {
    return null;
  }
}

export function writeJson(key: string, value: unknown): void {
  try {
    localStorage.setItem(key, JSON.stringify(value));
  } catch {
    // storage unavailable or full — the in-memory state stays authoritative
  }
}
```

`frontend/src/lib/tasks/settings.ts`:

```ts
import type { TaskFilter } from './filters';

export type TasksViewMode = 'list' | 'board';
export type TasksGroupBy = 'project' | 'priority' | 'due';

/** The Tasks page's persisted filter set (spec §Persistence). Search text and "Show done" expansions are session-local and never stored. */
export type TasksFilterSettings = {
  mode: TasksViewMode;
  view: TaskFilter;
  assignee: 'user' | 'agent' | null;
  groupBy: TasksGroupBy;
};

export const TASKS_FILTERS_KEY = 'valea.tasks.filters';
export const TODAY_ASSIGNEE_KEY = 'valea.today.assignee';

export const DEFAULT_TASKS_FILTER_SETTINGS: TasksFilterSettings = {
  mode: 'list',
  view: 'today',
  assignee: null,
  groupBy: 'project'
};

/**
 * Field-wise decode: each stored field falls back ALONE, so one unknown enum
 * value (a future release's setting, a hand-edited store) never resets the
 * neighbours the user still recognizes.
 */
export function decodeTasksFilterSettings(raw: unknown): TasksFilterSettings {
  const rec = raw !== null && typeof raw === 'object' && !Array.isArray(raw) ? (raw as Record<string, unknown>) : {};
  return {
    mode: rec.mode === 'board' ? 'board' : DEFAULT_TASKS_FILTER_SETTINGS.mode,
    view: rec.view === 'all' ? 'all' : DEFAULT_TASKS_FILTER_SETTINGS.view,
    assignee: rec.assignee === 'user' || rec.assignee === 'agent' ? rec.assignee : null,
    groupBy:
      rec.groupBy === 'priority' || rec.groupBy === 'due' ? rec.groupBy : DEFAULT_TASKS_FILTER_SETTINGS.groupBy
  };
}

/** Today-page toggle: only the literal 'user' narrows to Mine; anything else is Everyone. */
export function decodeTodayAssignee(raw: unknown): 'user' | null {
  return raw === 'user' ? 'user' : null;
}
```

Append to `frontend/src/lib/tasks/filters.ts` (below the existing exports; reuse the existing `dueDate`, `sortTasks`, `todayFilter`, `isCompleted`, `PRIORITY_RANK` module internals — do NOT duplicate them):

```ts
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

/** The empty-Today "Next up" picker: open backlog (outside the today view), standard sort, capped. */
export function nextUp(tasks: TaskEntry[], todayIso: string, limit: number): TaskEntry[] {
  const today = new Set(todayFilter(tasks, todayIso).map((task) => task.id));
  return sortTasks(
    tasks.filter((task) => !isCompleted(task) && !today.has(task.id))
  ).slice(0, limit);
}
```

- [ ] **Step 4: Run the tests, verify green** — same command as Step 2. Then the full unit sweep: `cd frontend && npx vitest run`. Expected: all pass, no existing test broken.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/persist.ts frontend/src/lib/persist.test.ts frontend/src/lib/tasks/settings.ts frontend/src/lib/tasks/settings.test.ts frontend/src/lib/tasks/filters.ts frontend/src/lib/tasks/filters.test.ts
git commit -m "feat(tasks): persistence guard, filter settings codec, and list maths"
```

---

### Task 2: Board column model

**Files:**
- Create: `frontend/src/lib/tasks/board.ts`
- Test: `frontend/src/lib/tasks/board.test.ts`

**Interfaces:**
- Consumes: `TaskEntry`, `orderTaskRows` from `lib/tasks/filters.ts`.
- Produces: `type BoardColumn = { status: string; label: string; custom: boolean; tasks: TaskEntry[] }`; `DEFAULT_BOARD_STATUSES = ['open', 'in_progress', 'done'] as const`; `boardLabel(status: string): string`; `deriveColumns(tasks: TaskEntry[]): BoardColumn[]`; `dropPatch(task: TaskEntry, columnStatus: string): { status: string } | null`.

- [ ] **Step 1: Write the failing tests** — `frontend/src/lib/tasks/board.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { normalizeTask } from './filters';
import { DEFAULT_BOARD_STATUSES, boardLabel, deriveColumns, dropPatch } from './board';

const t = (raw: Record<string, unknown>) => normalizeTask({ id: 'x', title: 't', ...raw });

describe('deriveColumns', () => {
  it('always emits Open · In progress · Done, in order, even empty', () => {
    expect(deriveColumns([]).map((c) => c.status)).toEqual([...DEFAULT_BOARD_STATUSES]);
    expect(deriveColumns([]).every((c) => !c.custom)).toBe(true);
  });

  it('empty-string status lands in Open (the resting state)', () => {
    const cols = deriveColumns([t({ id: 'a', status: '' })]);
    expect(cols.find((c) => c.status === 'open')!.tasks.map((x) => x.id)).toEqual(['a']);
  });

  it('custom statuses get their own columns after the defaults, first-seen order, verbatim label', () => {
    const cols = deriveColumns([
      t({ id: 'a', status: 'waiting' }),
      t({ id: 'b', status: 'blocked' }),
      t({ id: 'c', status: 'waiting' })
    ]);
    expect(cols.map((c) => c.status)).toEqual(['open', 'in_progress', 'done', 'waiting', 'blocked']);
    const waiting = cols.find((c) => c.status === 'waiting')!;
    expect(waiting.custom).toBe(true);
    expect(waiting.label).toBe('waiting');
    expect(waiting.tasks.map((x) => x.id)).toEqual(['a', 'c']);
  });

  it('dropped never gets a column and dropped entries appear nowhere', () => {
    const cols = deriveColumns([t({ id: 'a', status: 'dropped' })]);
    expect(cols.map((c) => c.status)).toEqual([...DEFAULT_BOARD_STATUSES]);
    expect(cols.flatMap((c) => c.tasks)).toEqual([]);
  });

  it('column rows are orderTaskRows-sorted', () => {
    const cols = deriveColumns([
      t({ id: 'later', status: 'open', due: '2026-09-01' }),
      t({ id: 'urgent', status: 'open', today: true })
    ]);
    expect(cols[0].tasks.map((x) => x.id)).toEqual(['urgent', 'later']);
  });
});

describe('boardLabel', () => {
  it('titles the known trio, passes custom through verbatim', () => {
    expect(boardLabel('open')).toBe('Open');
    expect(boardLabel('in_progress')).toBe('In progress');
    expect(boardLabel('done')).toBe('Done');
    expect(boardLabel('Waiting on Nadja')).toBe('Waiting on Nadja');
  });
});

describe('dropPatch', () => {
  it('patches to the target column status verbatim, including custom columns', () => {
    expect(dropPatch(t({ id: 'a', status: 'open' }), 'waiting')).toEqual({ status: 'waiting' });
  });
  it('null for same-column drops, id-less tasks, and empty-string-status→open no-ops', () => {
    expect(dropPatch(t({ id: 'a', status: 'done' }), 'done')).toBeNull();
    expect(dropPatch(normalizeTask({ title: 'no id', status: 'open' }), 'done')).toBeNull();
    expect(dropPatch(t({ id: 'a', status: '' }), 'open')).toBeNull();
  });
});
```

- [ ] **Step 2: Run, verify fail** — `cd frontend && npx vitest run src/lib/tasks/board.test.ts`.

- [ ] **Step 3: Implement** — `frontend/src/lib/tasks/board.ts`:

```ts
/**
 * The board's column model (spec §Board view). Pure: the component renders
 * exactly what this derives, so the design's one custom-status promise —
 * a status Valea doesn't know becomes a column instead of breaking — is
 * pinned here, not in markup.
 */
import { orderTaskRows, type TaskEntry } from './filters';

export const DEFAULT_BOARD_STATUSES = ['open', 'in_progress', 'done'] as const;

const DEFAULT_LABELS: Record<string, string> = { open: 'Open', in_progress: 'In progress', done: 'Done' };

export type BoardColumn = { status: string; label: string; custom: boolean; tasks: TaskEntry[] };

export function boardLabel(status: string): string {
  return DEFAULT_LABELS[status] ?? status;
}

/** `""` (no status) reads as Open, matching the list's resting-state rule. */
function columnStatusOf(task: TaskEntry): string {
  return task.status === '' ? 'open' : task.status;
}

/**
 * Open · In progress · Done always (empty columns are drop targets), then one
 * column per additional distinct status in first-seen order, labeled
 * verbatim. `dropped` entries live behind Clear done, never on the board.
 */
export function deriveColumns(tasks: TaskEntry[]): BoardColumn[] {
  const visible = tasks.filter((task) => columnStatusOf(task) !== 'dropped');
  const statuses: string[] = [...DEFAULT_BOARD_STATUSES];
  for (const task of visible) {
    const status = columnStatusOf(task);
    if (!statuses.includes(status)) statuses.push(status);
  }
  return statuses.map((status) => ({
    status,
    label: boardLabel(status),
    custom: !(DEFAULT_BOARD_STATUSES as readonly string[]).includes(status),
    tasks: orderTaskRows(visible.filter((task) => columnStatusOf(task) === status))
  }));
}

/** The patch a drop writes — or null when the drop is a no-op or the card can't be addressed. */
export function dropPatch(task: TaskEntry, columnStatus: string): { status: string } | null {
  if (task.id === null) return null;
  if (columnStatusOf(task) === columnStatus) return null;
  return { status: columnStatus };
}
```

- [ ] **Step 4: Run, verify green**, then full sweep `npx vitest run`.
- [ ] **Step 5: Commit** — `git add frontend/src/lib/tasks/board.ts frontend/src/lib/tasks/board.test.ts && git commit -m "feat(tasks): board column model"`

---

### Task 3: Greeting and day-summary maths

**Files:**
- Create: `frontend/src/lib/today/greeting.ts`
- Test: `frontend/src/lib/today/greeting.test.ts`

**Interfaces:**
- Produces: `greetingForHour(hour: number): string`; `dateOverline(date: Date): string`; `type SummarySegment = { text: string; tone: 'meta' | 'warn' }`; `daySummarySegments(input: { todayCount: number; overdueCount: number; attentionCount: number; nextEventTime: string | null }): SummarySegment[]`.

- [ ] **Step 1: Write the failing tests** — `frontend/src/lib/today/greeting.test.ts`:

```ts
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
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — `frontend/src/lib/today/greeting.ts`:

```ts
/**
 * The Today header's words (spec §Header). Pure and locale-injectable so the
 * hour/date/summary rules are testable; the route passes the live clock.
 * No user name exists in the product — the greeting stays impersonal.
 */
export function greetingForHour(hour: number): string {
  if (hour >= 5 && hour < 12) return 'Good morning';
  if (hour >= 12 && hour < 18) return 'Good afternoon';
  return 'Good evening';
}

/** "Thursday, August 6" — the §11 overline date. CSS uppercases; this stays plain text. */
export function dateOverline(date: Date, locale?: string): string {
  return date.toLocaleDateString(locale, { weekday: 'long', month: 'long', day: 'numeric' });
}

export type SummarySegment = { text: string; tone: 'meta' | 'warn' };

/**
 * The one-line day summary. Parts drop at zero so a quiet day reads quietly;
 * the renderer joins with " · " and the whole line hides when nothing is left.
 * `todayCount` already includes overdue (they are today's work too).
 */
export function daySummarySegments(input: {
  todayCount: number;
  overdueCount: number;
  attentionCount: number;
  nextEventTime: string | null;
}): SummarySegment[] {
  const segments: SummarySegment[] = [];
  if (input.todayCount > 0) {
    segments.push({ text: `${input.todayCount} ${input.todayCount === 1 ? 'task' : 'tasks'} for today`, tone: 'meta' });
  }
  if (input.overdueCount > 0) segments.push({ text: `${input.overdueCount} overdue`, tone: 'warn' });
  if (input.attentionCount > 0) {
    segments.push({
      text:
        input.attentionCount === 1
          ? '1 thing needs your attention'
          : `${input.attentionCount} things need your attention`,
      tone: 'meta'
    });
  }
  if (input.nextEventTime !== null) segments.push({ text: `next event ${input.nextEventTime}`, tone: 'meta' });
  return segments;
}
```

(Note the test passes `'en-US'` — give `dateOverline` the optional `locale` second parameter as shown, defaulting to the runtime locale.)

- [ ] **Step 4: Run, verify green; full sweep.**
- [ ] **Step 5: Commit** — `git add frontend/src/lib/today/greeting.ts frontend/src/lib/today/greeting.test.ts && git commit -m "feat(today): greeting, date overline, and day-summary maths"`

---

### Task 4: Cockpit sections for every ICM (backend + wire + normalizer)

**Files:**
- Modify: `backend/lib/valea/cockpit.ex` (`icm_section/1`, moduledoc, `@doc` for `today/0`)
- Modify: `frontend/src/lib/api/client.ts` (`cockpitTodayFields`: replace `'ok'` with `'todayJson'` in the sections list)
- Modify: `frontend/src/lib/today/cockpit.ts` (type + normalizer)
- Test: backend cockpit/rpc tests (locate with `grep -rl "icm_section\|cockpit_today\|Cockpit.today" backend/test`), `frontend/src/lib/today/` normalizer test (extend the existing cockpit normalizer test if one exists — `ls frontend/src/lib/today/`; create `cockpit.test.ts` there if not).

**Interfaces:**
- Produces (wire): every enabled `kind: :icm` mount yields a section; new string field `"today_json"` ∈ `"present" | "absent" | "unreadable"`; `"ok"` is REMOVED. `absent` sections carry `"updated_at" => nil, "notes" => nil, "prepared" => []` and the tasks line as usual.
- Produces (frontend): `TodaySection.todayJson: 'present' | 'absent' | 'unreadable'` (replaces `ok: boolean`). Missing field → `'absent'` (quiet); present-but-unknown value → `'unreadable'` (calm note) — the spec's leniency reading.

- [ ] **Step 1: Write the failing backend tests.** Find the existing cockpit section tests (`grep -rn "today.json" backend/test/valea/cockpit_test.exs` — adjust to the real file). Add/adapt cases, following the file's existing setup helpers for building a workspace with mounted ICMs:

```elixir
test "an ICM without today.json still yields a section, state absent, tasks intact" do
  # setup: enabled ICM with tasks.json but NO today.json (delete/omit the file)
  {:ok, payload} = Valea.Cockpit.today()
  section = Enum.find(payload["sections"], &(&1["mount_key"] == "w3d"))
  assert section["today_json"] == "absent"
  assert section["notes"] == nil
  assert section["prepared"] == []
  assert is_map(section["tasks"])
end

test "a readable today.json reports present" do
  # setup: write valid today.json into the mount root
  {:ok, payload} = Valea.Cockpit.today()
  section = Enum.find(payload["sections"], &(&1["mount_key"] == "w3d"))
  assert section["today_json"] == "present"
end

test "a malformed today.json reports unreadable and keeps the tasks line" do
  # setup: write "{not json" into today.json
  {:ok, payload} = Valea.Cockpit.today()
  section = Enum.find(payload["sections"], &(&1["mount_key"] == "w3d"))
  assert section["today_json"] == "unreadable"
  assert is_map(section["tasks"])
end

test "no section carries the retired ok field" do
  {:ok, payload} = Valea.Cockpit.today()
  refute Enum.any?(payload["sections"], &Map.has_key?(&1, "ok"))
end
```

Also update any EXISTING test asserting `"ok" =>` or asserting an absent-file ICM yields no section — those assertions now invert. Search: `grep -rn "\"ok\"" backend/test/valea/cockpit_test.exs backend/test/valea_web/rpc_test.exs`.

- [ ] **Step 2: Run, verify the new tests fail** — `cd backend && mix test test/valea/cockpit_test.exs` (real path from Step 1's grep).

- [ ] **Step 3: Implement backend.** In `backend/lib/valea/cockpit.ex`, replace `icm_section/1` + `unreadable_section/2` (currently ~lines 134–157):

```elixir
  # A section for EVERY enabled ICM (redesign spec 2026-08-06): the tasks line
  # and the briefing state are independent facts, and an absent today.json
  # must never hide real tasks again. "today_json" says exactly what happened
  # to the briefing file: "present" | "absent" | "unreadable".
  defp icm_section(mount) do
    base = %{"mount_key" => mount.name, "icm_name" => mount.manifest.name}

    case File.read(Path.join(mount.root, "today.json")) do
      {:error, :enoent} ->
        base |> Map.put("today_json", "absent") |> Map.merge(empty_fields()) |> with_tasks(mount)

      {:error, _reason} ->
        unreadable_section(base, mount)

      {:ok, raw} ->
        case parse_today(raw) do
          {:ok, fields} ->
            base |> Map.put("today_json", "present") |> Map.merge(fields) |> with_tasks(mount)

          :error ->
            unreadable_section(base, mount)
        end
    end
  end

  defp unreadable_section(base, mount) do
    base |> Map.put("today_json", "unreadable") |> Map.merge(empty_fields()) |> with_tasks(mount)
  end
```

Remove the `Enum.reject(&is_nil/1)` in `icm_sections/0` only if nothing else can return nil (it can't after this change — but leave the pipe if the reject is shared). Update the moduledoc/`@doc` sentence "one per enabled ICM that has a readable `today.json`" to "one per enabled ICM; `today_json` reports the briefing file's state (present | absent | unreadable)".

- [ ] **Step 4: Run backend tests green** — `mix test <cockpit test file> <rpc test file>`, then `mix test` full.

- [ ] **Step 5: Regenerate the wire types.** In `frontend/src/lib/api/client.ts` `cockpitTodayFields`, replace `'ok'` with `'todayJson'` in the sections list. Then check whether the Ash action declares section fields explicitly: `grep -n "today_json\|sections" backend/lib/valea/api/*.ex` — if the action's typed field list names section keys, add `today_json` there. Run `cd backend && mix ash_typescript.codegen && mix ash_typescript.codegen --check` (must end fresh); commit whatever it regenerates.

- [ ] **Step 6: Write the failing frontend normalizer tests.** In `frontend/src/lib/today/cockpit.test.ts` (create if absent):

```ts
import { describe, expect, it } from 'vitest';
import { normalizeCockpitToday } from './cockpit';

const section = (extra: Record<string, unknown>) => ({
  sections: [{ mount_key: 'w3d', icm_name: 'w3d', ...extra }]
});

describe('section todayJson state', () => {
  it('accepts both spellings and all three states', () => {
    for (const state of ['present', 'absent', 'unreadable'] as const) {
      expect(normalizeCockpitToday(section({ today_json: state })).sections[0].todayJson).toBe(state);
      expect(normalizeCockpitToday(section({ todayJson: state })).sections[0].todayJson).toBe(state);
    }
  });
  it('missing field degrades quiet (absent); unknown value degrades honest (unreadable)', () => {
    expect(normalizeCockpitToday(section({})).sections[0].todayJson).toBe('absent');
    expect(normalizeCockpitToday(section({ today_json: 'exploded' })).sections[0].todayJson).toBe('unreadable');
  });
});
```

- [ ] **Step 7: Implement the normalizer.** In `frontend/src/lib/today/cockpit.ts`: change `TodaySection`'s `ok: boolean` to `todayJson: 'present' | 'absent' | 'unreadable'` (keep the field's doc comment style), and in `normalizeSection`:

```ts
const todayJsonRaw = pick(raw, 'today_json', 'todayJson');
const todayJson =
  todayJsonRaw === 'present' || todayJsonRaw === 'absent' || todayJsonRaw === 'unreadable'
    ? todayJsonRaw
    : todayJsonRaw === undefined
      ? 'absent'
      : 'unreadable';
```

The old `routes/+page.svelte` consumer of `section.ok` still compiles against the old field — update its two uses minimally now (`{#if !section.ok}` → `{#if section.todayJson === 'unreadable'}`, and the sections-exist branch keys off sections with `todayJson === 'present'` for the prepared block) so the app builds; Task 10 replaces this page wholesale. Run `npx vitest run` + `npx svelte-check` equivalent (`npm run check` — confirm the script name with `cat frontend/package.json | grep -A5 scripts`).

- [ ] **Step 8: Run everything green** — backend `mix test`, frontend `npx vitest run` + the check script, codegen `--check` fresh.

- [ ] **Step 9: Commit**

```bash
git add backend/lib/valea/cockpit.ex backend/test frontend/src/lib/api/client.ts frontend/src/lib/today/cockpit.ts frontend/src/lib/today/cockpit.test.ts frontend/src/routes/+page.svelte
git commit -m "feat(cockpit): a section for every ICM, today_json state replaces ok"
```

---

### Task 5: Persisted settings store

**Files:**
- Create: `frontend/src/lib/tasks/settings.svelte.ts`
- Test: `frontend/src/lib/tasks/settings.svelte.test.svelte.ts` — NOTE the `.test.svelte.ts` suffix (runes project). Look at `frontend/src/lib/stores/theme.test.svelte.ts` first and mirror its structure and its untrack mutation-pin style.

**Interfaces:**
- Consumes: Task 1's `persist.ts` + `settings.ts` exports.
- Produces: `tasksSettings` singleton with `filters: TasksFilterSettings` (`$state`), `todayAssignee: 'user' | null` (`$state`), `setFilters(patch: Partial<TasksFilterSettings>): void`, `setTodayAssignee(value: 'user' | null): void`. Constructor seeds from storage; every setter persists via `untrack`ed `writeJson` (write path must not subscribe the caller — the `theme.svelte.ts` bug class).

- [ ] **Step 1: Write the failing runes tests** (structure mirrored from `theme.test.svelte.ts` — read it first; stub `localStorage` the same way `persist.test.ts` does):

```ts
import { describe, expect, it, vi, afterEach } from 'vitest';
import { TASKS_FILTERS_KEY, TODAY_ASSIGNEE_KEY } from './settings';

// Fresh module per test: the singleton reads storage at construction.
async function freshStore() {
  vi.resetModules();
  const mod = await import('./settings.svelte');
  return mod.tasksSettings;
}

function stubStorage(seed: Record<string, string> = {}) {
  const store = new Map(Object.entries(seed));
  vi.stubGlobal('localStorage', {
    getItem: (k: string) => store.get(k) ?? null,
    setItem: (k: string, v: string) => void store.set(k, v)
  });
  return store;
}

afterEach(() => vi.unstubAllGlobals());

describe('tasksSettings', () => {
  it('seeds from storage, field-wise', async () => {
    stubStorage({ [TASKS_FILTERS_KEY]: JSON.stringify({ mode: 'board', groupBy: 'nope' }) });
    const s = await freshStore();
    expect(s.filters.mode).toBe('board');
    expect(s.filters.groupBy).toBe('project');
  });

  it('setFilters merges a patch and persists the WHOLE record', async () => {
    const store = stubStorage();
    const s = await freshStore();
    s.setFilters({ view: 'all' });
    expect(s.filters.view).toBe('all');
    expect(JSON.parse(store.get(TASKS_FILTERS_KEY)!)).toEqual(s.filters);
  });

  it('today assignee round-trips its own key', async () => {
    const store = stubStorage();
    const s = await freshStore();
    s.setTodayAssignee('user');
    expect(store.get(TODAY_ASSIGNEE_KEY)).toBe(JSON.stringify('user'));
    expect(s.todayAssignee).toBe('user');
  });

  it('a broken localStorage still yields a working in-memory store', async () => {
    vi.stubGlobal('localStorage', { getItem: undefined, setItem: undefined });
    const s = await freshStore();
    expect(s.filters.mode).toBe('list');
    expect(() => s.setFilters({ mode: 'board' })).not.toThrow();
    expect(s.filters.mode).toBe('board');
  });
});
```

Additionally mirror `theme.test.svelte.ts`'s untrack pin (an `$effect` that reads a different `$state`, calls `setFilters`, and must not rerun when `filters` changes) — copy its exact harness pattern; if that pattern proves inapplicable to this store shape, say so in the report rather than forcing it.

- [ ] **Step 2: Run, verify fail** — `cd frontend && npx vitest run src/lib/tasks/settings.svelte.test.svelte.ts`.

- [ ] **Step 3: Implement** — `frontend/src/lib/tasks/settings.svelte.ts`:

```ts
/**
 * Persisted filter settings for the Tasks page + the Today assignee toggle
 * (spec §Persistence). One store so there is exactly one owner of the two
 * storage keys. Write paths are `untrack`ed — a store method that reads its
 * own `$state` while writing subscribes the CALLER to that state, the
 * `theme.svelte.ts` bug class this repo already fixed once.
 */
import { untrack } from 'svelte';
import { readJson, writeJson } from '../persist';
import {
  DEFAULT_TASKS_FILTER_SETTINGS,
  TASKS_FILTERS_KEY,
  TODAY_ASSIGNEE_KEY,
  decodeTasksFilterSettings,
  decodeTodayAssignee,
  type TasksFilterSettings
} from './settings';

class TasksSettingsStore {
  filters = $state<TasksFilterSettings>(decodeTasksFilterSettings(readJson(TASKS_FILTERS_KEY)));
  todayAssignee = $state<'user' | null>(decodeTodayAssignee(readJson(TODAY_ASSIGNEE_KEY)));

  setFilters(patch: Partial<TasksFilterSettings>): void {
    untrack(() => {
      this.filters = { ...this.filters, ...patch };
      writeJson(TASKS_FILTERS_KEY, this.filters);
    });
  }

  setTodayAssignee(value: 'user' | null): void {
    untrack(() => {
      this.todayAssignee = value;
      writeJson(TODAY_ASSIGNEE_KEY, value);
    });
  }
}

export const tasksSettings = new TasksSettingsStore();
```

- [ ] **Step 4: Run green; full sweep** (`npx vitest run`).
- [ ] **Step 5: Commit** — `git add frontend/src/lib/tasks/settings.svelte.ts frontend/src/lib/tasks/settings.svelte.test.svelte.ts && git commit -m "feat(tasks): persisted filter-settings store"`

---

### Task 6: Row toolkit — pills, glyphs, shapes, TaskRow density pass

**Files:**
- Create: `frontend/src/lib/components/tasks/OverduePill.svelte`, `frontend/src/lib/components/tasks/PriorityGlyph.svelte`
- Modify: `frontend/src/lib/components/tasks/task-shapes.ts`, `frontend/src/lib/components/tasks/TaskRow.svelte`
- Test: `frontend/src/lib/components/tasks/task-shapes.test.ts` (extend)

**Interfaces:**
- Consumes: Task 1's `overdueDays`, `overduePillText`, `priorityGlyph`.
- Produces:
  - `task-shapes.ts`: `sourceChipLabel(label: string): string` (basename of a path-ish label; non-paths unchanged) applied inside `taskSourceRender`'s returned `label`; `taskSession(task: TaskEntry): string | null` (the `session` raw key, string-typed or null); existing `showsAgentBadge` REPLACED by `showsAssigneeGear(task: Pick<TaskEntry,'assignee'>): boolean` (true iff `assignee === 'agent'`).
  - `OverduePill.svelte` props: `{ days: number }` — renders `overduePillText(days)` in a pill: `bg-warn-tint text-warn-ink border-warn-border rounded-full border px-2 py-0.5 text-[10.5px] font-semibold tabular-nums`.
  - `PriorityGlyph.svelte` props: `{ priority: string | null }` — renders the glyph with `text-warn-ink` (high), `text-warn-dot` (medium), `text-ink-meta` (low), `w-4 text-center text-[11px] font-bold`; renders nothing for null/unknown.
  - `TaskRow.svelte` props gain: `onToggleToday: () => void`, `sessionLive?: boolean | null` (null = unknown). The `FROM ASSISTANT` badge markup is deleted.

- [ ] **Step 1: Write the failing shape tests** (extend `task-shapes.test.ts`, following its existing style):

```ts
describe('sourceChipLabel', () => {
  it('shrinks path-ish labels to their basename, leaves plain text alone', () => {
    expect(sourceChipLabel('01_clients/kita-villa-vesta/CONTEXT.md')).toBe('CONTEXT.md');
    expect(sourceChipLabel('CONTEXT.md')).toBe('CONTEXT.md');
    expect(sourceChipLabel('from a phone call')).toBe('from a phone call');
    expect(sourceChipLabel('a/b/')).toBe('a/b/'); // trailing slash: not a file label, keep verbatim
  });
});

describe('taskSession', () => {
  it('string session key or null; wrong types are null', () => {
    expect(taskSession(normalizeTask({ id: 'a', session: 's-1' }))).toBe('s-1');
    expect(taskSession(normalizeTask({ id: 'a' }))).toBeNull();
    expect(taskSession(normalizeTask({ id: 'a', session: 7 }))).toBeNull();
  });
});

describe('showsAssigneeGear', () => {
  it('gear only for assignee=agent (creator provenance retired from rows)', () => {
    expect(showsAssigneeGear({ assignee: 'agent' })).toBe(true);
    expect(showsAssigneeGear({ assignee: 'user' })).toBe(false);
    expect(showsAssigneeGear({ assignee: null })).toBe(false);
  });
});
```

Delete/replace the existing `showsAgentBadge` tests. `sourceChipLabel` rule: if the label contains `/` and does not end with `/`, return the substring after the last `/`; otherwise return it unchanged.

- [ ] **Step 2: Run, verify fail** — `npx vitest run src/lib/components/tasks/task-shapes.test.ts`.

- [ ] **Step 3: Implement shapes.** In `task-shapes.ts`: add `sourceChipLabel` + `taskSession`, apply `sourceChipLabel` to the `label` field inside `taskSourceRender`'s return values (both the link and text kinds), replace `showsAgentBadge` with `showsAssigneeGear` (grep for the old name's uses: `TaskRow.svelte` only). Run tests green.

- [ ] **Step 4: Build the two components.** `OverduePill.svelte`:

```svelte
<script lang="ts">
  import { overduePillText } from '$lib/tasks/filters';
  let { days }: { days: number } = $props();
</script>

<span class="bg-warn-tint text-warn-ink border-warn-border rounded-full border px-2 py-0.5 text-[10.5px] font-semibold tabular-nums">
  {overduePillText(days)}
</span>
```

`PriorityGlyph.svelte`:

```svelte
<script lang="ts">
  import { priorityGlyph } from '$lib/tasks/filters';
  let { priority }: { priority: string | null } = $props();
  const spec = $derived(priorityGlyph(priority));
</script>

{#if spec}
  <span
    class={[
      'w-4 shrink-0 text-center text-[11px] font-bold',
      spec.tone === 'high' ? 'text-warn-ink' : spec.tone === 'medium' ? 'text-warn-dot' : 'text-ink-meta'
    ]}
    aria-label={`priority ${priority}`}
  >{spec.glyph}</span>
{/if}
```

- [ ] **Step 5: Rework `TaskRow.svelte`** into the single-line density row. Keep: checkbox button (32px target, 15px visual), id-less repair affordance, sibling-not-nested interactive elements, the `group/row` hover pattern. Changes, in the row's flex order:
  1. checkbox (unchanged)
  2. `<PriorityGlyph priority={task.priority} />` — but when the priority is UNKNOWN (non-null, not high/medium/low) keep the verbatim text chip in the chip area instead (leniency).
  3. title button — now `truncate whitespace-nowrap` single-line (`text-[13.5px]`, done styling unchanged)
  4. inline chips, all `shrink-0`, in order: `⚙` gear (`showsAssigneeGear`, `text-ink-meta text-[11px]`, `title="assigned to the assistant"`, `aria-label` same), unknown-status chip (existing `statusChip`), unknown-priority text chip, `focus` marker (existing `task.today` act text), due chip — `OverduePill` when `overdueDays(task, todayIso) !== null`, else the existing due text tones; source chip (existing markup, label now basename via shapes); session chip when `taskSession(task) !== null`:
     ```svelte
     <a href={`/chat?session=${taskSession(task)}`} class="border-paper-chip-border text-ink-secondary hover:text-ink-heading inline-flex items-center gap-1 rounded-full border px-2 py-0.5 text-[10.5px] hover:underline">
       {#if sessionLive}<span class="bg-act-dot size-1.5 rounded-full" aria-hidden="true"></span>{/if}
       session
     </a>
     ```
  5. hover/focus action cluster (`opacity-0 group-hover/row:opacity-100 group-focus-within/row:opacity-100 focus-visible:opacity-100` — the existing overflow-trigger pattern): a `Today`/`Today ✓` text button calling `onToggleToday` (aria-label `Flag for today` / `Remove from today`), then the existing `⋯` DropdownMenu grown to items `Edit` (calls `onOpen`) and `Drop` (existing).
  6. The `FROM ASSISTANT` badge block and the `showsAgentBadge` import are deleted; the notes-wrap `<div class="mt-0.5 …">` second line is deleted — chips ride the single line (`min-w-0` on the title, `overflow-hidden` on the row's flex middle).
  Props added: `onToggleToday: () => void`, `sessionLive?: boolean | null`.

- [ ] **Step 6: Wire the new props at the call site** minimally: in `TasksTab.svelte` pass `onToggleToday={() => void toggleToday(icm.mountKey, task)}` with

```ts
async function toggleToday(mountKey: string, task: TaskEntry): Promise<void> {
  if (task.id === null) return;
  report(await tasksStore.patchTask(mountKey, task.id, { today: !task.today }));
}
```

and `sessionLive={null}` (Task 8 supplies the live lookup). Confirm `tasksStore.patchTask(mountKey, taskId, patch)` is the real signature (`grep -n "patchTask" frontend/src/lib/tasks/store.svelte.ts`).

- [ ] **Step 7: Suites + check** — `npx vitest run` and the `package.json` check script; both green.
- [ ] **Step 8: Commit**

```bash
git add frontend/src/lib/components/tasks frontend/src/lib/tasks
git commit -m "feat(tasks): single-line rows — overdue pill, priority glyph, gear, session chip, today toggle"
```

---

### Task 7: Tasks tab rework — controls, grouping, folding, next-up

**Files:**
- Modify: `frontend/src/lib/components/tasks/TasksTab.svelte` (major), `frontend/src/lib/components/tasks/QuickAdd.svelte` (restyle to the inline first-row), `frontend/src/routes/tasks/+page.svelte` (width + settings wiring)
- Test: extend `frontend/src/lib/tasks/filters.test.ts` only if new pure gaps appear (all maths landed in Task 1 — this task is wiring/markup)

**Interfaces:**
- Consumes: `tasksSettings` (Task 5), Task 1 maths, Task 6 row props.
- Produces: the tab renders from `tasksSettings.filters` (no local `filters` state); `TaskFilters`' `status` axis is gone from the UI (type may stay for `applyTaskFilters` compatibility — pass `status: null`).

- [ ] **Step 1: Controls row.** Replace the three-SegmentedControl block with (order, left→right; `flex flex-wrap items-center gap-2`):
  1. `SegmentedControl label="List or board" size="sm"` options `[{value:'list',label:'List'},{value:'board',label:'Board'}]` → `tasksSettings.setFilters({ mode })`.
  2. `SegmentedControl label="Which tasks"` options `[{value:'today',label:'Today',count:todayCount},{value:'all',label:'All',count:allCount}]` → `setFilters({ view })`. Counts: over the merged ledgers with the CURRENT assignee filter applied, search IGNORED (Global Constraints: count honesty; spec: search is transient):
     ```ts
     const assigneeNarrow = (rows: TaskEntry[]) =>
       rows.filter((task) => tasksSettings.filters.assignee === null || (task.assignee ?? 'user') === tasksSettings.filters.assignee);
     const todayCount = $derived(assigneeNarrow(icms.flatMap((icm) => todayFilter(icm.tasks, todayIso))).length);
     const allCount = $derived(assigneeNarrow(icms.flatMap((icm) => icm.tasks.filter((task) => !isCompleted(task)))).length);
     ```
     NOTE `allCount` counts OPEN (non-completed) tasks — the All view shows done rows folded, and a count including archived-pending rows would promise rows a click hides. State this in a comment.
  3. `SegmentedControl label="Whose tasks"` options `[{value:'user',label:'Mine'},{value:'agent',label:"Assistant's"},{value:'anyone',label:'Everyone'}]` mapping `'anyone'`↔`null` → `setFilters({ assignee })`.
  4. Group select (list mode only): `NativeSelect` labeled `Group`, options `project`/`priority`/`due` (labels `Project`, `Priority`, `Due date`) → `setFilters({ groupBy })`.
  5. Search: `<Input type="search" placeholder="Search tasks…" bind:value={search} class="ml-auto w-[200px]" aria-label="Search tasks" />`, `let search = $state('')`, applied with a `$derived` 150ms-debounced value (pattern: `let debounced = $state(''); $effect(() => { const q = search; const t = setTimeout(() => (debounced = q), 150); return () => clearTimeout(t); });`).
  The old status SegmentedControl is deleted; `statusBase`/`countByStatus` usages go with it (leave the tested functions in `filters.ts`).

- [ ] **Step 2: Rendering model.** Compute visible rows per view:

```ts
const filtered = $derived.by(() => {
  const rows = icms.flatMap((icm) =>
    applyTaskFilters(icm.tasks, { view: tasksSettings.filters.view, assignee: tasksSettings.filters.assignee, status: null }, todayIso)
      .filter((task) => matchesSearch(task, debounced))
      .map((task) => ({ icm, task }))
  );
  return rows;
});
```

Grouping (list mode): `groupBy === 'project'` keeps the existing per-ICM sections (open rows = not `isCompleted`; done rows fold — Step 3); `'priority'`/`'due'` group the flattened `filtered` via `groupByPriority`/`groupByDue` (open rows only), section headers = `group.label` overline + count. Within EVERY group render `splitOverdue` first: overdue rows under a warn overline `Overdue · {n}` (`text-warn-ink` on the overline, rows carry the pill via TaskRow) — EXCEPT inside `groupByDue`'s own `overdue` bucket (it IS the overdue group; no nested header). Project tag chip (`text-[9px] text-ink-meta`, icm name) appears on rows whenever `groupBy !== 'project'`.

- [ ] **Step 3: Done folding (project grouping).** Per ICM section: open rows always; done+dropped rows render only when that section's `showDone` (a `$state` `Set<string>` of mountKeys, session-local) contains the mount. Footer line when `doneCount > 0`:
  `{doneCount} done · <button>Show</button>/<button>Hide</button> · <button>Clear done</button>` — Clear done keeps the existing inline confirmation card verbatim. Sections with zero open AND zero done rows don't render (replaces `sectionVisible`'s `icm.tasks.length === 0` arm — the "No tasks yet." per-section note is deleted; unreadable-ledger and duplicate-id notes stay).

- [ ] **Step 4: Empty Today = Next up.** When `tasksSettings.filters.view === 'today'` and `filtered.length === 0` and no search text: render overline `Next up` + `nextUp(allOpenRows, todayIso, 5)` rows (each with a `Today` button calling `toggleToday`) + the line: `Nothing due, overdue, or flagged for today — pick from the backlog above, or see <button>All</button>.` (All switches the view). With search active and zero rows: `No tasks match "{search}".` The old two empty-state paragraphs are replaced by these.

- [ ] **Step 5: Quick add as first row.** Restyle `QuickAdd.svelte` to the row form: `+` glyph, borderless `Input` (`placeholder="Add a task…"`), project `NativeSelect` (unchanged logic), implicit `today: true` when view is today (existing behavior, now reading `tasksSettings.filters.view`); render it as the first row of the list area under the controls, `border-b border-paper-hairline pb-2`.

- [ ] **Step 6: Route.** `frontend/src/routes/tasks/+page.svelte`: content wrapper gains `max-w-[1100px]` for the list (`board` mode uses full width — wrapper class `$derived` on `tasksSettings.filters.mode`); remove nothing else. The page's own `filters` prop threading disappears (TasksTab reads `tasksSettings` directly).

- [ ] **Step 7: Suites + check green; commit**

```bash
git add frontend/src/lib/components/tasks frontend/src/routes/tasks
git commit -m "feat(tasks): persisted controls, grouping, done folding, next-up"
```

---

### Task 8: Hand to assistant

**Files:**
- Create: `frontend/src/lib/tasks/handoff.ts`
- Modify: `frontend/src/lib/components/tasks/TaskRow.svelte` (action button), `frontend/src/lib/components/tasks/TasksTab.svelte` (flow)
- Test: `frontend/src/lib/tasks/handoff.test.ts`

**Interfaces:**
- Consumes: `api.createAgentSession(mountKey, generation)`, `setInitialPrompt(sessionId, text)` from `$lib/stores/initial-prompt`, `tasksStore.patchTask`, `recentSessionsStore.groups`, `goto`.
- Produces: `handoffPrompt(task: TaskEntry, mountKey: string): string`; `sessionLiveById(groups: { sessions: { id: string; live: boolean }[] }[], sessionId: string): boolean | null`; TaskRow prop `onHandOff?: () => void` (button rendered only when provided and task addressable).

- [ ] **Step 1: Write the failing tests** — `frontend/src/lib/tasks/handoff.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { normalizeTask } from './filters';
import { handoffPrompt, sessionLiveById } from './handoff';

describe('handoffPrompt', () => {
  it('names the task id, title, and the ledger file; includes only present fields', () => {
    const prompt = handoffPrompt(
      normalizeTask({ id: 'tk_1', title: 'Rechnung stellen', notes: 'CHF 500', due: '2026-08-08', priority: 'high', source: '01_clients/CONTEXT.md' }),
      'w3d'
    );
    expect(prompt).toContain('tk_1');
    expect(prompt).toContain('Rechnung stellen');
    expect(prompt).toContain('CHF 500');
    expect(prompt).toContain('2026-08-08');
    expect(prompt).toContain('high');
    expect(prompt).toContain('01_clients/CONTEXT.md');
    expect(prompt).toContain('tasks.json');
  });
  it('omits absent fields without leaving labels behind', () => {
    const prompt = handoffPrompt(normalizeTask({ id: 'tk_2', title: 'Just a title' }), 'w3d');
    expect(prompt).not.toContain('Notes:');
    expect(prompt).not.toContain('Due:');
    expect(prompt).not.toContain('Priority:');
    expect(prompt).not.toContain('Source:');
  });
});

describe('sessionLiveById', () => {
  const groups = [{ sessions: [{ id: 's1', live: true }, { id: 's2', live: false }] }];
  it('true/false when found, null when unknown', () => {
    expect(sessionLiveById(groups, 's1')).toBe(true);
    expect(sessionLiveById(groups, 's2')).toBe(false);
    expect(sessionLiveById(groups, 'gone')).toBeNull();
  });
});
```

- [ ] **Step 2: Run, verify fail.**
- [ ] **Step 3: Implement** — `frontend/src/lib/tasks/handoff.ts`:

```ts
/**
 * Hand-a-task-to-the-assistant (spec §Hand to assistant). The prompt is the
 * contract: it anchors the session on the task's ledger entry so the agent
 * updates the SAME entry (`.valea/briefing.md` already teaches the ledger
 * rules); the UI flips status/assignee and records the session id itself,
 * so a crashed session never leaves an untraceable in_progress task.
 */
import type { TaskEntry } from './filters';

export function handoffPrompt(task: TaskEntry, mountKey: string): string {
  const lines = [
    `Please work on this task from ${mountKey}'s tasks.json ledger (entry id: ${task.id}).`,
    '',
    `Task: ${task.title ?? '(untitled)'}`
  ];
  if (task.notes !== null) lines.push(`Notes: ${task.notes}`);
  if (task.due !== null) lines.push(`Due: ${task.due}`);
  if (task.priority !== null) lines.push(`Priority: ${task.priority}`);
  if (task.source !== null) lines.push(`Source: ${task.source}`);
  lines.push(
    '',
    'When you finish, update this entry in tasks.json: set its status (done when complete), and add a short note of what you did. If you get blocked, set status back to open and record why in the notes.'
  );
  return lines.join('\n');
}

/** Live state of a session id from the recent-sessions groups — null when the id is beyond the recency window (chip renders without a dot). */
export function sessionLiveById(
  groups: { sessions: { id: string; live: boolean }[] }[],
  sessionId: string
): boolean | null {
  for (const group of groups) {
    const found = group.sessions.find((session) => session.id === sessionId);
    if (found) return found.live;
  }
  return null;
}
```

- [ ] **Step 4: Wire the flow.** TaskRow: add prop `onHandOff?: () => void`; in the hover action cluster, FIRST button when `onHandOff && addressable`: `→ Assistant` (aria-label `Hand to the assistant`). TasksTab:

```ts
let handingOff = $state<string | null>(null);

async function handOff(mountKey: string, task: TaskEntry): Promise<void> {
  if (task.id === null || handingOff !== null) return;
  handingOff = task.id;
  try {
    const created = await api.createAgentSession(mountKey, workspaceStore.generation ?? 0);
    if (!created.ok) {
      rowError =
        created.error === 'harness_unavailable'
          ? "The assistant isn't ready — open Settings → Agent (the gear in the sidebar) and run the checks."
          : 'The session could not be started. Please try again.';
      return;
    }
    const sessionId = (created.data as { id: string }).id;
    setInitialPrompt(sessionId, handoffPrompt(task, mountKey));
    const patched = await tasksStore.patchTask(mountKey, task.id, {
      status: 'in_progress',
      assignee: 'agent',
      session: sessionId
    });
    if (!patched.ok) {
      // The session exists and is reachable from Recent sessions; say why the
      // row didn't move rather than navigating away from the evidence.
      rowError = taskErrorMessage(patched.error);
      return;
    }
    void recentSessionsStore.refresh();
    void goto(`/chat?session=${sessionId}`);
  } finally {
    handingOff = null;
  }
}
```

Pass `onHandOff={() => void handOff(icm.mountKey, task)}` and `busy={busyTaskId === task.id || handingOff === task.id}`; replace Task 6's `sessionLive={null}` with `sessionLive={taskSession(task) === null ? null : sessionLiveById(recentSessionsStore.groups, taskSession(task)!)}` (import both). Confirm imports exist in TasksTab (`api`, `workspaceStore`, `setInitialPrompt`, `goto`, `recentSessionsStore`) — add the missing ones, copying the Today page's exact import paths.

- [ ] **Step 5: Suites + check green; commit**

```bash
git add frontend/src/lib/tasks/handoff.ts frontend/src/lib/tasks/handoff.test.ts frontend/src/lib/components/tasks
git commit -m "feat(tasks): hand a task to the assistant"
```

---

### Task 9: Board view

**Files:**
- Create: `frontend/src/lib/components/tasks/TaskBoard.svelte`, `BoardColumn.svelte`, `TaskCard.svelte`
- Modify: `frontend/src/lib/components/tasks/TasksTab.svelte` (mode branch)
- Test: none new (the model is Task 2; DnD handlers are thin wiring — state this in the task report)

**Interfaces:**
- Consumes: `deriveColumns`, `dropPatch`, `BoardColumn` (Task 2); `tasksStore.patchTask`, `clearDone`; Task 6 chips; `filtered` rows from Task 7.
- Produces: `TaskBoard` props `{ rows: { icm: TaskIcm; task: TaskEntry }[]; onOpen: (mountKey: string, task: TaskEntry) => void; onError: (message: string) => void }`.

- [ ] **Step 1: Build the components.**

`TaskCard.svelte` (props `{ task, icmName, sessionLive, draggable, onOpen, onDragStart }`):

```svelte
<button
  type="button"
  {draggable}
  ondragstart={onDragStart}
  onclick={onOpen}
  class="border-paper-border bg-paper-card shadow-card block w-full rounded-[10px] border p-2.5 text-left"
>
  <p class="text-ink-body line-clamp-2 text-[13px]">{task.title ?? '(untitled)'}</p>
  <div class="mt-1 flex flex-wrap items-center gap-1.5">
    <PriorityGlyph priority={task.priority} />
    <!-- gear, overdue pill / due text, session chip: the EXACT chip markup from TaskRow (Task 6), minus hover actions -->
    <span class="text-ink-meta text-[9px]">{icmName}</span>
  </div>
</button>
```

Id-less tasks render with `draggable={false}` plus the `ID_LESS_TASK_NOTE` line (import from task-shapes). Done-column cards get `opacity-75` + `line-through` title (the receipt reading).

`BoardColumn.svelte` (props `{ column: BoardColumn, children-per-card via snippet or direct composition, onDrop: (status: string) => void }`): a `flex-1 min-w-[220px]` container, `bg-paper-track border-paper-border rounded-[10px] border p-2.5` (custom columns add `border-dashed`), header `flex justify-between` — overline label + `tabular-nums` count; body `flex flex-col gap-2`; DnD: `ondragover={(e) => e.preventDefault()}`, `ondrop={(e) => { e.preventDefault(); onDrop(column.status); }}`.

`TaskBoard.svelte`: tracks `dragging: { mountKey: string; taskId: string } | null` (`$state`, set in each card's `onDragStart` via a lookup from the row list, cleared on `ondragend`) and an OPTIMISTIC overlay `pending = $state<Map<string, string>>(new Map())` keyed `${mountKey}/${taskId}` → column status (pre-flight ruling 2026-08-06: spec governs — the card follows the drop immediately and visibly reverts on failure). Columns derive THROUGH the overlay:

```ts
const columns = $derived(
  deriveColumns(
    rows.map(({ icm, task }) => {
      const override = pending.get(`${icm.mountKey}/${task.id}`);
      return override === undefined ? task : { ...task, status: override };
    })
  )
);
```

Renders `flex gap-3 items-start overflow-x-auto` of columns. Drop handler:

```ts
async function handleDrop(columnStatus: string): Promise<void> {
  const drag = dragging;
  dragging = null;
  if (drag === null) return;
  const row = rows.find((r) => r.icm.mountKey === drag.mountKey && r.task.id === drag.taskId);
  if (!row) return;
  const patch = dropPatch(row.task, columnStatus);
  if (patch === null) return;
  const key = `${drag.mountKey}/${drag.taskId}`;
  pending = new Map(pending).set(key, columnStatus); // card moves NOW
  const outcome = await tasksStore.patchTask(drag.mountKey, drag.taskId, patch);
  const next = new Map(pending);
  next.delete(key); // success: the re-listed store rows carry the new status; failure: the card snaps back
  pending = next;
  if (!outcome.ok) onError(taskErrorMessage(outcome.error));
}
```

(The overlay is per-drop and self-clearing on both outcomes, so it can never disagree with the file for longer than one in-flight write; a failed write reverts the card visibly with the error line explaining.)

Done column footer: `Archive all` button → inline confirmation (the Clear-done card pattern from TasksTab, listing `{icmName}: {n}` per project with done entries) → sequential `clearDone(mountKey)` per project; first failure → `onError(taskErrorMessage(...))` and stop.

- [ ] **Step 2: Mode branch in TasksTab.** `{#if tasksSettings.filters.mode === 'board'} <TaskBoard rows={filtered} onOpen={(mountKey, task) => …existing editor open…} onError={(m) => (rowError = m)} /> {:else} …list rendering… {/if}`. Group-by select hidden in board mode (Task 7 already scoped it). Quick add renders above both modes.

- [ ] **Step 3: Suites + check green** (`npx vitest run`, check script — svelte-check catches prop drift).
- [ ] **Step 4: Commit** — `git add frontend/src/lib/components/tasks && git commit -m "feat(tasks): status board with drag between columns"`

---

### Task 10: Today spine — layout, header, composer, attention, briefing

**Files:**
- Create: `frontend/src/lib/components/today/AttentionCard.svelte`, `frontend/src/lib/components/today/AgentBriefingCard.svelte`
- Modify: `frontend/src/routes/+page.svelte` (rebuild; KEEP: the load/refresh/push-subscription wiring, `resolveConflict`, `quickStart`, `activeMountKey` derivation, failure state, skeleton block — restyle only)
- Test: none new (pure pieces landed in Task 3)

**Interfaces:**
- Consumes: Task 3 greeting maths; Task 4 `todayJson`; existing `gitStore`, `scheduleNotice*`, `mountProvenanceLabel`, `knowledgeHref`, `Composer`, `NativeSelect`.
- Produces: `AttentionCard` props `{ gitRows: GitRepoStatus[]; notices: ScheduleNotice[]; resolving: string | null; resolveError: Record<string, string>; onResolve: (repo: GitRepoStatus) => void }` and exposes `attentionCount = gitRows.length + notices.length` computed at the CALL site for the summary line. `AgentBriefingCard` props `{ section: TodaySection }`.

- [ ] **Step 1: Layout scaffold.** Use `<MainColumn wide>` (the full-width variant — the default 660px prose cap is exactly what this redesign retires for Today) and hand-roll the centered two-region grid inside it:

```svelte
<div class="mx-auto grid w-full max-w-[1220px] grid-cols-1 gap-8 min-[1180px]:grid-cols-[minmax(0,880px)_300px]">
  <div class="min-w-0"><!-- main column --></div>
  <aside class="min-w-0 flex flex-col gap-3"><!-- rail (Task 11 fills; leave the aside in place) --></aside>
</div>
```

- [ ] **Step 2: Header.** Replace the current `<header>`:

```svelte
<header class="flex flex-col gap-1.5">
  <p class="text-overline">{dateOverline(now)}</p>
  <h1 class="font-display text-ink-heading text-[28px] leading-tight font-medium">{greetingForHour(now.getHours())}</h1>
  {#if summary.length > 0}
    <p class="text-[13px]">
      {#each summary as segment, i (segment.text)}
        {#if i > 0}<span class="text-ink-meta"> · </span>{/if}
        <span class={segment.tone === 'warn' ? 'text-warn-ink font-medium' : 'text-ink-meta'}>{segment.text}</span>
      {/each}
    </p>
  {/if}
</header>
```

`now` is `$state(new Date())` with the Tasks route's exact midnight-watch pattern (60s interval + visibilitychange — copy the block and its comment from `routes/tasks/+page.svelte`). `summary = $derived(daySummarySegments({ todayCount, overdueCount, attentionCount, nextEventTime }))` — todayCount/overdueCount arrive in Task 11 (use `0` placeholders wired to real values there; note it in the report), `attentionCount = gitAttention.length + interruptNotices.length`, `nextEventTime` Task 11 (null for now). The old mail/calendar summary `<p>` lines are DELETED.

- [ ] **Step 3: Composer with ICM picker.** Wrap the existing `Composer` block: left edge gains a `NativeSelect` (aria-label `Project for the new session`) listing `icmStore.groups` (value mount, label title), bound to `let quickMountKey = $state('')` seeded/repaired by the exact `$effect` pattern from TasksTab (MRU default = existing `quickTarget`); `quickStart` uses `quickMountKey` instead of `quickTarget`. Composer placeholder becomes `Start a session…`. Layout: `flex items-start gap-2` with the select `mt-*`-aligned to the composer's first row — match heights visually (the select is `h-8`).

- [ ] **Step 4: AttentionCard.** New component; card chrome `bg-warn-tint border-warn-border rounded-xl border p-4`; overline `text-overline text-warn-ink` reading `Needs attention`; rows: git rows exactly as the current page's Git section `<li>` markup (dot, `gitAttentionText`, button, error line — move it wholesale), then notice rows for `notice.kind === 'waiting' || notice.kind === 'failed'` using the current Schedules-section row markup (`scheduleNoticeText`, `scheduleNoticeHref`, timestamp). Render the card only when `gitRows.length + notices.length > 0`. The page's old standalone `Git` and `Schedules` sections are DELETED (registered notices re-home in Task 11's rail).

- [ ] **Step 5: AgentBriefingCard.** New component; renders one section with `todayJson === 'present'`: card `bg-paper-card border-paper-border rounded-xl border p-4`; overline row `FROM YOUR AGENT · {mountProvenanceLabel(section.icmName)}` + `updatedAt` timestamp (existing `formatTimestamp` — move it into the component or a small shared util in `lib/today/today-view.ts`, Task 11 needs it too); `notes` paragraph; `prepared` list (existing markup moved). In the route: `{#each today.sections.filter((s) => s.todayJson === 'present') as section (section.mountKey)} <AgentBriefingCard {section} /> {/each}` directly below the AttentionCard; sections with `todayJson === 'unreadable'` render the calm line `today.json couldn't be read` under an overline naming the ICM; `absent` renders NOTHING. The old "Nothing prepared yet." explainer box, the old per-section tasks-line block, and the old "New mail" section are all DELETED (mail re-homes in Task 11's rail; the whole-page empty state lands there too).

- [ ] **Step 6: Suites + check green** (normalizer tests still pass; svelte-check clean). The page is intentionally mid-rebuild (no tasks/agenda/rail yet) — commit as such.
- [ ] **Step 7: Commit** — `git add frontend/src/routes/+page.svelte frontend/src/lib/components/today && git commit -m "feat(today): editorial spine — grid, greeting header, composer picker, attention and briefing cards"`

---

### Task 11: Today tasks, agenda, rail, empty state

**Files:**
- Create: `frontend/src/lib/today/today-view.ts`, `frontend/src/lib/components/today/TodayTasks.svelte`, `AgendaSection.svelte`, `RailCard.svelte`
- Modify: `frontend/src/routes/+page.svelte`
- Test: `frontend/src/lib/today/today-view.test.ts`

**Interfaces:**
- Consumes: `tasksStore` (+ `icmStore.onIcmChanged` re-wiring for it), Task 1 maths, Task 5 `tasksSettings.todayAssignee`, Task 6 chips + editor dialog pattern (import `TaskEditor` + `Dialog` exactly as `TasksTab.svelte` hosts them), `api.listCalendarEvents(from, to, zone)` + `occurrenceToGridEvents` from `calendar-shapes.ts` (read `routes/calendar/+page.svelte`'s fetch/normalize block and mirror it for a single-day range), `CockpitToday.mail/recentSessions/scheduleNotices/calendar`.
- Produces (`today-view.ts`):
  - `type TailSegment = { text: string; emphasis: boolean }`
  - `todayTailSegments(input: { backlogCount: number; hiddenAssistantCount: number }): TailSegment[]` — `[{text:'31 more in the backlog',emphasis:false},{text:'1 with the assistant',emphasis:false},{text:'Plan today →',emphasis:true}]`; zero parts drop; `Plan today →` always present when backlogCount > 0 OR hiddenAssistantCount > 0; empty array when both are 0.
  - `railMailRows(mail: MailAccountSummary[], cap: number): { account: string; msgId: string; line: string }[]` — merged newest-first by `date` (nulls last), line = `fromName ?? fromEmail ?? subject ?? '(unknown)'` + ` — ` + `subject ?? '(no subject)'` truncation left to CSS.
  - `agendaRows(events: CalendarEvent[]): { time: string; title: string; duration: string | null }[]` — sorted by `startMin`, time = `timeLabel(startMin)`, duration = `durationLabel`-style `45 min`/`2 h` from `endMin - startMin` (write a local `agendaDuration(min: number): string | null` — null when ≤ 0).
  - `nextEventTime(events: CalendarEvent[], nowMin: number): string | null` — first event with `startMin >= nowMin`, `timeLabel`ed.

- [ ] **Step 1: Write the failing tests** for all four `today-view.ts` functions (same value-table style as Tasks 1–3; cover: tail-segment drops, mail merge ordering with null dates, agenda sort + duration text, next-event boundary `startMin === nowMin` → included, none upcoming → null).

- [ ] **Step 2: Run fail → implement `today-view.ts` → run green.**

- [ ] **Step 3: TodayTasks.svelte.** Props `{ merged: { icm: TaskIcm; task: TaskEntry }[]; todayIso: string }` — the ROUTE computes the merged today-view rows (so it can also derive `todayCount`/`overdueCount` for the summary line without recomputation); the component reads `tasksSettings` directly for the toggle and calls `tasksStore` for mutations. Structure:
  - Section header row: overline `Today` + count (`{shown} of {total} tasks` when the toggle hides rows, else `{total} tasks`), `SegmentedControl size="sm" label="Whose tasks"` options `[{value:'user',label:'Mine'},{value:'anyone',label:'Everyone'}]` → `tasksSettings.setTodayAssignee(value === 'user' ? 'user' : null)`.
  - Rows: merged `todayFilter` across `tasksStore.taskIcms`, assignee-narrowed (`(task.assignee ?? 'user') === 'user'` when Mine), then `splitOverdue`: overdue under warn overline `Overdue · {n}`, rest under the `Today` header's own list. Row rendering REUSES `TaskRow` with `onToggleDone`/`onOpen`/`onDrop`/`onRepair`/`onToggleToday` wired to a local copy of TasksTab's handlers (extract nothing; copy the small handlers — they are 3–6 lines each and the store is shared). Project tag on every row.
  - Editor: the same `Dialog + TaskEditor` host block as TasksTab (copy, keyed identically).
  - Tail line from `todayTailSegments` (`backlogCount` = open ∧ not-today-view ∧ assignee-narrowed; `hiddenAssistantCount` = today-view ∧ `assignee === 'agent'` when Mine active, else 0); `Plan today →` renders as `<a href="/tasks">`; emphasis segments `text-act`, others `text-ink-meta`.
  - Exposes its counts upward: the route needs `todayCount`/`overdueCount` for the summary line — compute BOTH in the route (import the same filters; the route already holds `tasksStore`) and pass nothing down that the component recomputes; alternatively lift the merged rows to the route and pass them in as a prop. Choose the prop shape: route computes `merged: { icm: TaskIcm; task: TaskEntry }[]` (today view, assignee-narrowed) and passes `{ merged, todayIso }`; TodayTasks renders from the prop; the route derives `todayCount = merged.length`, `overdueCount = merged.filter(...overdueDays...).length`. State this in the component doc comment.
- [ ] **Step 4: AgendaSection.svelte.** Props `{ enabled: boolean; todayIso: string; zone: string }` — `enabled = today.calendar !== null`. On mount + when `todayIso` changes: `api.listCalendarEvents(todayIso, todayIso, zone)` (zone = `Intl.DateTimeFormat().resolvedOptions().timeZone`), normalize via the calendar route's occurrence path, `agendaRows`. States: loading (two `Skeleton` lines), error (`Couldn't read today's events.` + Retry button), empty (`No events today.` quiet line), rows (`time · title · duration` — `.time` tabular 40px, title flex, duration `text-ink-meta`). Section overline `Agenda`. Hidden entirely when `!enabled`. The route passes `nextEventTime(events, minutesOfDay(now))` back up via a `onEvents: (events: CalendarEvent[]) => void` callback prop (route stores them for the summary line).
- [ ] **Step 5: Rail.** `RailCard.svelte`: props `{ overline: string }` + children snippet; chrome `bg-paper-card border-paper-border rounded-xl border p-3.5` + `text-overline mb-2`. In the route's `<aside>`:
  1. New mail: `railMailRows(today.mail.filter((m) => m.configured), 4)` rows (deep links exactly like the old New-mail section) + per-account footer `{account} · {unreadCount} unread` linking `/mail?account=…`; card hidden when no configured accounts.
  2. Schedules: `today.scheduleNotices.filter((n) => n.kind === 'registered')` rows (existing notice markup); card hidden when empty.
  3. Recent sessions: the existing Recent-sessions list markup moved inside a card, cap 5; hidden when empty.
- [ ] **Step 6: Empty page + skeleton.** Whole-page empty state (no attention rows, zero briefing/unreadable sections, `merged.length === 0` AND no backlog, agenda disabled-or-empty, all rail cards hidden): one `bg-paper-card border-paper-border rounded-xl border p-5` card: `**Your day, once there's something in it.** Each project keeps a shared task list you and the assistant both work from — add a task on the Tasks page and it shows up here. You can also ask the assistant to prepare a morning briefing for any project; it appears at the top of this page.` (strong first sentence `text-ink-heading`, rest `text-ink-body`). Backlog-but-nothing-today gets the tail line via TodayTasks already — not this card. Update the skeleton block to sketch the new shape (header lines + one card + two rows + rail column stub).
- [ ] **Step 7: Suites + check green; commit**

```bash
git add frontend/src/routes/+page.svelte frontend/src/lib/components/today frontend/src/lib/today
git commit -m "feat(today): live tasks with assignee toggle, agenda, rail cards, empty state"
```

---

### Task 12: Schedules tab ordering fixes

**Files:**
- Modify: `frontend/src/lib/components/tasks/SchedulesTab.svelte`
- Test: none (pure reordering; the tab's logic tests live in `schedule-shapes.test.ts` and are untouched)

- [ ] **Step 1:** Move the `New schedule` composer block ABOVE the kill-switch block. Read the file top to bottom first; the kill-switch section (the `Pause all schedules` heading, explanatory sentence, and button — currently the tab's first block) moves to the BOTTOM of the tab as a quiet footer: overline `Schedules pause`, the existing sentence + button on one row, `border-t border-paper-hairline pt-4 mt-6`. Render it only when at least one schedule exists across ICMs (any `icm.schedules.length > 0` — read the tab's actual data shape and use its idiom).
- [ ] **Step 2:** Per-ICM sections with zero schedules collapse: when EVERY section is empty render exactly one line `No schedules here yet.` under the composer (delete the per-ICM repeats); when SOME have schedules, empty sections don't render at all.
- [ ] **Step 3:** Suites + check green (`npx vitest run` — schedule-shapes untouched, svelte-check clean).
- [ ] **Step 4: Commit** — `git add frontend/src/lib/components/tasks/SchedulesTab.svelte && git commit -m "fix(tasks): schedules tab leads with New schedule, kill switch becomes a footer"`

---

### Task 13: Warn-on-tint contrast invariant + docs

**Files:**
- Modify: `frontend/src/lib/design/contrast.test.ts`, `docs/DESIGN_SYSTEM.md`, `docs/superpowers/specs/2026-08-06-today-tasks-redesign-design.md` (Status line), possibly `frontend/src/routes/layout.css` (ONLY if the invariant fails — see Step 2)

- [ ] **Step 1: Write the invariant** in `contrast.test.ts`, inside the existing `describe.each(['light','dark'])` structure (read the file's helpers — `readPalette`, `contrastRatio` — and follow its idiom):

```ts
it('overdue pill: warn-ink on warn-tint holds AA (the pill made this pair load-bearing)', () => {
  expect(contrastRatio(palette['--warn-ink'], palette['--warn-tint'])).toBeGreaterThanOrEqual(4.5);
});
```

- [ ] **Step 2: Run it** — `npx vitest run src/lib/design/contrast.test.ts`. If EITHER palette fails: adjust that palette's `--warn-ink` (darken in light / lighten in dark) or `--warn-tint` (lighten in light / darken in dark) in `layout.css` by the SMALLEST step that clears 4.5 while keeping the hue family — then re-run the FULL design suite (`npx vitest run src/lib/design/`) to prove no other invariant broke, and update the matching cell in `docs/DESIGN_SYSTEM.md`'s palette tables. If both palettes already pass, `layout.css` stays untouched.
- [ ] **Step 3: Docs.** `docs/DESIGN_SYSTEM.md`: §11 layout grid line gains `Today: main 880 + rail 300 (folds under <1180)`; add a short "Tasks board" note under the §4/§5 component notes (status columns, custom statuses verbatim as dashed columns, overdue pill = warn-tint/warn-ink/warn-border, priority glyphs ‼/!/·, gear = assistant-assigned). Spec Status line → `Status: Implemented (plan 2026-08-06)`.
- [ ] **Step 4: Full gates.** `cd frontend && npx vitest run` (all projects), check script, `cd ../backend && mix test`, `mix ash_typescript.codegen --check`.
- [ ] **Step 5: Commit** — `git add frontend/src/lib/design/contrast.test.ts docs frontend/src/routes/layout.css && git commit -m "test(design): pin warn-on-tint AA; document the redesign"`

---

## Self-Review

Run after writing: spec coverage (every spec § maps to a task — Part 1 → 3/4/10/11, Part 2 → 1/2/5/6/7/8/9/12, Part 3 → 6/13, testing § → per-task steps), placeholder scan, type/name consistency across tasks (`tasksSettings`, `TasksFilterSettings`, `overdueDays`, `deriveColumns`, `handoffPrompt`, `todayJson` — spelled identically everywhere).
