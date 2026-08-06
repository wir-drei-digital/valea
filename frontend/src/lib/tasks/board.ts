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

/**
 * `hasOwn`, never a bare lookup: the status is a string out of the user's own
 * `tasks.json`, so `"toString"` (or `"constructor"`) would otherwise resolve
 * down the prototype chain and hand a FUNCTION back where a label belongs. A
 * status Valea doesn't know is rendered verbatim — including that one.
 */
export function boardLabel(status: string): string {
  return Object.hasOwn(DEFAULT_LABELS, status) ? DEFAULT_LABELS[status] : status;
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

/**
 * The board's row set: the view's rows, plus the ledger's finished ones.
 *
 * Why the board reaches past the view filter (controller ruling 2026-08-06):
 * the Today filter excludes completed entries, so in the DEFAULT view the Done
 * column was permanently empty — and a card dropped on it disappeared instead
 * of landing, which reads as data loss rather than as a status change. Finished
 * entries are ambient RECEIPTS, not view rows; the list already takes that
 * reading when its project footer counts the ledger rather than the fold.
 *
 * `receipts` must arrive already narrowed by whatever applies to every card
 * (assignee, search): this function decides nothing about relevance, it only
 * unions. Entries already present are dropped by OBJECT IDENTITY, never by id —
 * ids are nullable and duplicable (`nextUp` carries the same note), and the
 * store hands both lists the very same references.
 */
export function boardTasks(rows: TaskEntry[], receipts: TaskEntry[]): TaskEntry[] {
  const seen = new Set(rows);
  return [...rows, ...receipts.filter((task) => !seen.has(task))];
}

/**
 * The entry a column derives from: the pending drop's status while a write is in
 * flight, otherwise the file's — with `""` normalized to `open`.
 *
 * Why the normalization happens HERE, before `deriveColumns` (carried question
 * from Task 2's review): `columnStatusOf` already reads `""` as Open, but
 * `orderTaskRows` sorts every unknown status AFTER every known one, so inside
 * the Open column a today-flagged `""` card sat below the calm `open` ones and
 * the split read as a sorting glitch. In the LIST that partition is right — a
 * row with a status Valea doesn't know carries it as a chip and belongs last —
 * but on the board the column IS the status, so a card that reached Open has
 * nothing left to explain. `orderTaskRows` itself is untouched (the list depends
 * on it); the board hands it a COPY.
 *
 * That copy is also where the optimistic drop overlay lands, so column
 * placement and drag feedback can never disagree about where a card is. It is a
 * DISPLAY projection: `raw` deliberately keeps the file's own status, because
 * nothing writes from a board card (`dropPatch` is given the row's real entry).
 */
export function boardTask(task: TaskEntry, pendingStatus?: string): TaskEntry {
  const status = pendingStatus ?? (task.status === '' ? 'open' : task.status);
  // Same reference when nothing changed — the board maps a derived entry back to
  // its project by identity, and a needless copy would lose that.
  return status === task.status ? task : { ...task, status };
}

/** The patch a drop writes — or null when the drop is a no-op or the card can't be addressed. */
export function dropPatch(task: TaskEntry, columnStatus: string): { status: string } | null {
  if (task.id === null) return null;
  if (columnStatusOf(task) === columnStatus) return null;
  return { status: columnStatus };
}
