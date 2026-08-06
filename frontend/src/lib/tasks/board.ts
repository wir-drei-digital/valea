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
