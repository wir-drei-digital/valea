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
