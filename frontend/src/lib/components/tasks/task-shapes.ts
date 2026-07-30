/**
 * Render decisions for the Tasks tab (`TasksTab.svelte` / `TaskRow.svelte` /
 * `TaskEditor.svelte`) — the pure half, so the tab's copy and its degenerate-
 * entry handling are pinned by tests rather than by reading markup.
 *
 * Everything here follows the spec's leniency contract: a ledger Valea cannot
 * parse gets a CALM note (never an error state), unknown statuses render as
 * text, duplicate ids degrade softly with "first wins", and an id-less entry
 * gets a repair affordance instead of silently unclickable row actions.
 */
import { knowledgeHref } from '$lib/shell/nav';
import { isKnownStatus, type TaskEntry } from '$lib/tasks/filters';

/**
 * Structural stand-in for `TasksStore`'s `LedgerStatus` — declared here so this
 * leaf render module never imports the store (and, through it, the socket) just
 * for a three-member string union.
 */
export type LedgerStatusLike = 'ok' | 'absent' | 'unreadable';

/** The spec's own wording for a `tasks.json` Valea cannot parse. */
export const MALFORMED_TASKS_NOTE = 'unreadable — fix by hand or ask the agent';

/**
 * The per-ICM note under the provenance header, or `null` when there is nothing
 * to say. An ABSENT ledger is not a problem — it is an ICM with no tasks yet,
 * and the tab's empty state covers it; only `unreadable` earns a note.
 */
export function ledgerNote(status: LedgerStatusLike): string | null {
  return status === 'unreadable' ? MALFORMED_TASKS_NOTE : null;
}

/**
 * "two entries share the id t-1 — the first one wins here", or `null` when
 * every id is unique. Tasks are inert (nothing executes), so a duplicate is a
 * calm note rather than an exclusion — unlike a duplicate SCHEDULE id, which
 * excludes every carrier from execution.
 */
export function duplicateIdNote(tasks: TaskEntry[]): string | null {
  const seen = new Set<string>();
  const duplicates: string[] = [];
  for (const task of tasks) {
    if (task.id === null) continue;
    if (seen.has(task.id) && !duplicates.includes(task.id)) duplicates.push(task.id);
    seen.add(task.id);
  }
  if (duplicates.length === 0) return null;
  const ids = duplicates.join(', ');
  const subject = duplicates.length === 1 ? `the id ${ids}` : `the ids ${ids}`;
  return `Two or more entries share ${subject} — the first one wins here.`;
}

/** Display label for a status, with an unknown one shown VERBATIM (spec: unknown statuses render as text). */
export function statusLabel(status: string): string {
  switch (status) {
    case 'open':
      return 'Open';
    case 'in_progress':
      return 'In progress';
    case 'done':
      return 'Done';
    case 'dropped':
      return 'Dropped';
    case '':
      return 'No status';
    default:
      return status;
  }
}

export function priorityLabel(priority: string | null): string | null {
  if (priority === null) return null;
  switch (priority) {
    case 'high':
      return 'High';
    case 'medium':
      return 'Medium';
    case 'low':
      return 'Low';
    default:
      return priority;
  }
}

export function assigneeLabel(assignee: string | null): string {
  switch (assignee) {
    case 'agent':
      return 'Agent';
    case 'user':
    case null:
      return 'Me';
    default:
      return assignee;
  }
}

/** `created_by: "agent"` earns the badge; anything else (including absent) does not. */
export function showsAgentBadge(task: TaskEntry): boolean {
  return task.createdBy === 'agent';
}

/**
 * The row's due chip: `null` when there is no parseable due, otherwise the raw
 * date plus a tone the row styles. A `due` string that isn't a date still shows
 * — as `tone: 'unparsed'` — because hiding it would make a typo invisible.
 */
export function dueChip(
  task: TaskEntry,
  todayIso: string
): { text: string; tone: 'overdue' | 'today' | 'later' | 'unparsed' } | null {
  if (task.due === null) return null;
  const parsed = parsedDue(task.due);
  if (parsed === null) return { text: task.due, tone: 'unparsed' };
  if (parsed < todayIso) return { text: parsed, tone: 'overdue' };
  if (parsed === todayIso) return { text: 'Today', tone: 'today' };
  return { text: parsed, tone: 'later' };
}

function parsedDue(due: string): string | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(due)) return null;
  const date = new Date(`${due}T00:00:00Z`);
  if (Number.isNaN(date.getTime())) return null;
  return date.toISOString().slice(0, 10) === due ? due : null;
}

/**
 * How to render a task's `source` (spec §Data model: "Rendered as text/chip;
 * only locators Valea recognizes become links").
 *
 * Recognized:
 *   - a mail message locator — `mail:<account>/<folder…>/<msg_id>`, the shape
 *     the briefing teaches agents (`mail:w3d/INBOX/<msg_id>`) — links into
 *     `/mail`, exactly like the cockpit's own unread rows;
 *   - a file locator — an ICM-relative path with a file extension, resolved
 *     against the task's OWN ICM (`(mount_key, rel_path)` is how every piece of
 *     ICM content is addressed) — links into the file browser.
 *
 * Everything else — a URL, a sentence, a bare folder name, an absolute or
 * escaping path — stays plain TEXT. The spec enumerates exactly two link-worthy
 * locator kinds, and a confidently wrong link out of freeform provenance is
 * worse than the text.
 */
export type TaskSourceRender =
  | { kind: 'mail'; label: string; href: string }
  | { kind: 'file'; label: string; href: string }
  | { kind: 'text'; label: string };

export function taskSourceRender(source: string, mountKey: string): TaskSourceRender | null {
  const trimmed = source.trim();
  if (trimmed === '') return null;

  if (trimmed.toLowerCase().startsWith('mail:')) {
    const parts = trimmed.slice('mail:'.length).split('/').filter((part) => part !== '');
    if (parts.length >= 3) {
      const account = parts[0];
      const msgId = parts[parts.length - 1];
      return {
        kind: 'mail',
        label: trimmed,
        href: `/mail?account=${encodeURIComponent(account)}&message=${encodeURIComponent(msgId)}`
      };
    }
    return { kind: 'text', label: trimmed };
  }

  if (isIcmRelativeFile(trimmed)) {
    return { kind: 'file', label: trimmed, href: knowledgeHref(mountKey, trimmed) };
  }

  return { kind: 'text', label: trimmed };
}

/**
 * An ICM-relative path with a file extension and no escape: `clients/lea.md`
 * yes, `/etc/passwd` no, `../secrets.md` no, `https://example.com/a.html` no
 * (scheme), `Clients` no (a folder name is not a file locator).
 */
function isIcmRelativeFile(value: string): boolean {
  if (/\s/.test(value)) return false;
  if (value.startsWith('/') || value.startsWith('~')) return false;
  if (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(value)) return false;
  const segments = value.split('/');
  if (segments.some((segment) => segment === '' || segment === '.' || segment === '..')) return false;
  return /\.[A-Za-z0-9]{1,8}$/.test(segments[segments.length - 1]);
}

/**
 * The repair affordance for an entry with no `id` (spec §Leniency contract:
 * "Entries without `id` are not executable and not addressable" — for tasks,
 * not addressable means Valea cannot patch or archive it).
 *
 * v1 repair is a COPY, not an in-place fix: `create_task` writes a fresh
 * properly-stamped entry with the same fields, and the note tells the user the
 * original line is theirs to delete. Valea will not guess an id into a line it
 * cannot address, and `mutate_task` has no nil-id form to reach it with.
 */
export const ID_LESS_TASK_NOTE =
  'This entry has no id, so Valea can’t edit or archive it. Copy it into a proper task, then delete the original line by hand.';

/** The fields a repair copy carries over — everything the original had, minus what Valea stamps itself. */
export function repairFields(task: TaskEntry): Record<string, unknown> {
  const { id, created_at, created_by, updated_at, done_at, ...rest } = task.raw;
  void id;
  void created_at;
  void created_by;
  void updated_at;
  void done_at;
  return rest;
}

/** The editor's status options: the four known ones, plus the entry's own unknown value so saving NORMALIZES it. */
export function statusOptions(current: string): { value: string; label: string }[] {
  const known = ['open', 'in_progress', 'done', 'dropped'].map((value) => ({ value, label: statusLabel(value) }));
  if (current === '' || isKnownStatus(current)) return known;
  return [{ value: current, label: `${current} (unknown)` }, ...known];
}

/** What `TaskEditor.svelte`'s form holds — every field a string or boolean, exactly as an `<input>` gives it. */
export type TaskEditForm = {
  title: string;
  notes: string;
  due: string;
  today: boolean;
  priority: string;
  assignee: string;
  status: string;
};

/**
 * The editor's PATCH: only the fields the user actually changed, so
 * `mutate_task`'s entry-level read-patch-write keeps round-tripping every key
 * Valea doesn't understand (spec §Leniency contract).
 *
 * Every optional text field clears to `null`, TITLE INCLUDED (review round 1,
 * L8 — it used to send `""`). `null` is a real edit meaning "no value", and it
 * is what `normalizeTask` reads back for an absent field; `""` would have made
 * an emptied title a different shape on disk from a title that was never there,
 * and would have left `"title": ""` in the file for every other reader to
 * puzzle over.
 *
 * Pure and tested here rather than living in the component, per this module's
 * contract: what a Save actually writes is a decision, not markup.
 */
export function taskEditPatch(task: TaskEntry, form: TaskEditForm): Record<string, unknown> {
  const patch: Record<string, unknown> = {};
  const title = form.title.trim();

  if (title !== (task.title ?? '')) patch.title = title === '' ? null : title;
  if (form.notes !== (task.notes ?? '')) patch.notes = form.notes === '' ? null : form.notes;
  if (form.due !== (task.due ?? '')) patch.due = form.due === '' ? null : form.due;
  if (form.today !== task.today) patch.today = form.today;
  if (form.priority !== (task.priority ?? '')) patch.priority = form.priority === '' ? null : form.priority;
  // `assignee` has a DEFAULT rather than an empty state (the select offers no
  // blank option), so it compares against the same `'user'` the seed uses.
  if (form.assignee !== (task.assignee ?? 'user')) patch.assignee = form.assignee;
  if (form.status !== task.status) patch.status = form.status;

  return patch;
}

/** Shown in the editor when the entry carries a status Valea doesn't know — the spec's other repair affordance. */
export function unknownStatusHint(status: string): string | null {
  return status !== '' && !isKnownStatus(status)
    ? `“${status}” isn’t a status Valea knows. Pick one below to normalize it.`
    : null;
}

/**
 * Backend error codes → one calm sentence each (`Valea.Api.Tasks.error_for/1`).
 * An unrecognized code falls back to a generic line rather than leaking an atom
 * name into the UI.
 */
export function taskErrorMessage(code: string): string {
  switch (code) {
    case 'workspace_not_open':
      return 'No workspace is open.';
    case 'workspace_changed':
      return 'The workspace changed while you were editing. Reload and try again.';
    case 'icm_unavailable':
      return 'That project isn’t available right now.';
    case 'not_found':
      return 'That task is no longer in the file.';
    case 'conflict':
      return 'Something else wrote the file at the same time. Nothing was written — try again.';
    case 'unreadable':
      return `The task file is ${MALFORMED_TASKS_NOTE}.`;
    case 'internal_error':
      return 'Valea couldn’t write the task file.';
    default:
      return 'That didn’t work. Please try again.';
  }
}
