import { describe, expect, it } from 'vitest';
import {
  ID_LESS_TASK_NOTE,
  MALFORMED_TASKS_NOTE,
  assigneeLabel,
  dueChip,
  duplicateIdNote,
  ledgerNote,
  priorityLabel,
  repairFields,
  showsAgentBadge,
  statusLabel,
  statusOptions,
  taskEditPatch,
  taskErrorMessage,
  taskSourceRender,
  unknownStatusHint,
  type TaskEditForm
} from './task-shapes';
import { normalizeTask } from '$lib/tasks/filters';

const TODAY = '2026-07-30';

function task(fields: Record<string, unknown>) {
  return normalizeTask({ id: 't-1', title: 'A task', status: 'open', ...fields });
}

// The Tasks tab renders a `list_tasks` payload verbatim — entry maps with the
// FILE's own snake_case keys (`Valea.Api.Tasks`: `tasks` is an unconstrained
// `{:array, :map}` so unknown keys survive). This fixture is that wire shape.
const FIXTURE = {
  mountKey: 'primary',
  icmName: 'Mara Lindt Coaching',
  status: 'ok' as const,
  tasks: [
    {
      id: 't-8f3a2c',
      title: 'Send Kita offer follow-up',
      status: 'open',
      assignee: 'user',
      due: '2026-07-30',
      today: true,
      priority: 'high',
      source: 'mail:w3d/INBOX/<msg-1@host>',
      created_by: 'agent',
      created_at: '2026-07-29T08:00:00Z'
    },
    { id: 't-2', title: 'Draft the invoice', status: 'in_progress', assignee: 'agent', created_by: 'user' },
    { id: 't-2', title: 'A duplicate id', status: 'open' },
    { title: 'No id at all', status: 'open' },
    { id: 't-4', title: 'Blocked on the bank', status: 'waiting_on_bank' }
  ].map(normalizeTask)
};

describe('ledgerNote', () => {
  it('flags only an unreadable ledger, with the spec’s calm wording', () => {
    expect(ledgerNote('unreadable')).toBe(MALFORMED_TASKS_NOTE);
    expect(ledgerNote('absent')).toBeNull();
    expect(ledgerNote('ok')).toBeNull();
  });
});

describe('duplicateIdNote', () => {
  it('names the shared id once and says the first entry wins', () => {
    const note = duplicateIdNote(FIXTURE.tasks);
    expect(note).toBe('Two or more entries share the id t-2 — the first one wins here.');
  });

  it('is null when every id is unique, and ignores id-less entries', () => {
    expect(duplicateIdNote([task({ id: 'a' }), task({ id: 'b' }), normalizeTask({ title: 'no id' })])).toBeNull();
  });

  it('does not repeat an id that appears three times, and lists several ids', () => {
    const rows = [task({ id: 'a' }), task({ id: 'a' }), task({ id: 'a' }), task({ id: 'b' }), task({ id: 'b' })];
    expect(duplicateIdNote(rows)).toBe('Two or more entries share the ids a, b — the first one wins here.');
  });
});

describe('statusLabel', () => {
  it('labels the four known statuses and echoes an unknown one verbatim', () => {
    expect(statusLabel('open')).toBe('Open');
    expect(statusLabel('in_progress')).toBe('In progress');
    expect(statusLabel('done')).toBe('Done');
    expect(statusLabel('dropped')).toBe('Dropped');
    expect(statusLabel('waiting_on_bank')).toBe('waiting_on_bank');
    expect(statusLabel('')).toBe('No status');
  });
});

describe('priorityLabel / assigneeLabel', () => {
  it('labels the known values and echoes anything else', () => {
    expect(priorityLabel('high')).toBe('High');
    expect(priorityLabel('urgent')).toBe('urgent');
    expect(priorityLabel(null)).toBeNull();
    expect(assigneeLabel('agent')).toBe('Assistant');
    expect(assigneeLabel('user')).toBe('Me');
    expect(assigneeLabel(null)).toBe('Me');
    expect(assigneeLabel('team')).toBe('team');
  });
});

describe('showsAgentBadge', () => {
  it('badges only agent-created entries', () => {
    expect(showsAgentBadge(FIXTURE.tasks[0])).toBe(true);
    expect(showsAgentBadge(FIXTURE.tasks[1])).toBe(false);
    expect(showsAgentBadge(task({}))).toBe(false);
  });
});

describe('dueChip', () => {
  it('speaks in days, not ISO strings — nobody does date arithmetic in a task list', () => {
    expect(dueChip(task({ due: '2026-07-29' }), TODAY)).toEqual({ text: '1 day overdue', tone: 'overdue' });
    expect(dueChip(task({ due: '2026-07-01' }), TODAY)).toEqual({ text: '29 days overdue', tone: 'overdue' });
    expect(dueChip(task({ due: TODAY }), TODAY)).toEqual({ text: 'due today', tone: 'today' });
    expect(dueChip(task({ due: '2026-07-31' }), TODAY)).toEqual({ text: 'due tomorrow', tone: 'later' });
    expect(dueChip(task({ due: '2026-08-30' }), TODAY)).toEqual({ text: 'due Aug 30', tone: 'later' });
    // The year appears only when it isn't this year's.
    expect(dueChip(task({ due: '2027-01-05' }), TODAY)).toEqual({ text: 'due Jan 5, 2027', tone: 'later' });
    // A typo stays VISIBLE — hiding it would make the mistake invisible.
    expect(dueChip(task({ due: '2026-13-99' }), TODAY)).toEqual({
      text: 'due 2026-13-99 (not a date)',
      tone: 'unparsed'
    });
    expect(dueChip(task({}), TODAY)).toBeNull();
  });
});

describe('taskSourceRender', () => {
  it('links a mail message locator into /mail', () => {
    expect(taskSourceRender('mail:w3d/INBOX/<msg-1@host>', 'primary')).toEqual({
      kind: 'mail',
      label: 'mail:w3d/INBOX/<msg-1@host>',
      href: '/mail?account=w3d&message=%3Cmsg-1%40host%3E'
    });
  });

  it('takes the LAST segment as the message id, so a nested folder still resolves', () => {
    const render = taskSourceRender('mail:w3d/INBOX/Clients/m-9', 'primary');
    expect(render).toMatchObject({ kind: 'mail', href: '/mail?account=w3d&message=m-9' });
  });

  it('leaves a mail-ish locator with too few segments as plain text', () => {
    expect(taskSourceRender('mail:w3d/INBOX', 'primary')).toEqual({ kind: 'text', label: 'mail:w3d/INBOX' });
  });

  it('links an ICM-relative file path against the task’s own ICM', () => {
    expect(taskSourceRender('clients/lea.md', 'primary')).toEqual({
      kind: 'file',
      label: 'clients/lea.md',
      href: '/knowledge/primary/clients/lea.md'
    });
    expect(taskSourceRender('brochure.pdf', 'clients')).toMatchObject({
      kind: 'file',
      href: '/knowledge/clients/brochure.pdf'
    });
  });

  it('never links anything the spec does not name as a locator', () => {
    const plain = [
      'https://example.com/page.html',
      'Kita follow-up conversation',
      '/etc/passwd',
      '../secrets.md',
      './notes.md',
      '~/notes.md',
      'Clients',
      'clients/'
    ];
    for (const source of plain) {
      expect(taskSourceRender(source, 'primary')).toEqual({ kind: 'text', label: source });
    }
  });

  it('is null for an empty or whitespace-only source', () => {
    expect(taskSourceRender('', 'primary')).toBeNull();
    expect(taskSourceRender('   ', 'primary')).toBeNull();
  });
});

describe('the id-less repair affordance', () => {
  it('tells the user Valea cannot address the entry, and that the original is theirs to delete', () => {
    expect(ID_LESS_TASK_NOTE).toContain('no id');
    expect(ID_LESS_TASK_NOTE).toContain('delete the original');
  });

  it('carries every field over except the ones Valea stamps itself', () => {
    const original = normalizeTask({
      title: 'No id at all',
      status: 'open',
      priority: 'low',
      colour: 'green',
      created_at: '2026-01-01T00:00:00Z',
      created_by: 'agent',
      updated_at: '2026-01-02T00:00:00Z',
      done_at: null
    });

    expect(repairFields(original)).toEqual({ title: 'No id at all', status: 'open', priority: 'low', colour: 'green' });
  });
});

describe('statusOptions / unknownStatusHint', () => {
  it('offers the four known statuses for a known or absent current value', () => {
    expect(statusOptions('open').map((o) => o.value)).toEqual(['open', 'in_progress', 'done', 'dropped']);
    expect(statusOptions('').map((o) => o.value)).toEqual(['open', 'in_progress', 'done', 'dropped']);
    expect(unknownStatusHint('open')).toBeNull();
    expect(unknownStatusHint('')).toBeNull();
  });

  it('keeps an unknown status selectable so saving normalizes it', () => {
    expect(statusOptions('waiting_on_bank')[0]).toEqual({
      value: 'waiting_on_bank',
      label: 'waiting_on_bank (unknown)'
    });
    expect(unknownStatusHint('waiting_on_bank')).toContain('normalize');
  });
});

describe('taskErrorMessage', () => {
  it('maps every code `Valea.Api.Tasks.error_for/1` can produce', () => {
    const codes = [
      'workspace_not_open',
      'workspace_changed',
      'icm_unavailable',
      'not_found',
      'conflict',
      'unreadable',
      'internal_error'
    ];
    for (const code of codes) {
      const message = taskErrorMessage(code);
      expect(message).not.toBe('That didn’t work. Please try again.');
      expect(message.length).toBeGreaterThan(0);
    }
    // An unknown code never leaks an atom name into the UI.
    expect(taskErrorMessage('some_new_atom')).toBe('That didn’t work. Please try again.');
  });
});

describe('taskEditPatch', () => {
  const entry = task({
    title: 'Send the offer',
    notes: 'draft in clients/lea.md',
    due: '2026-08-01',
    today: true,
    priority: 'high',
    assignee: 'agent',
    status: 'in_progress'
  });

  /** The editor's fields as they are SEEDED from an entry — the untouched form. */
  function seed(overrides: Partial<TaskEditForm> = {}): TaskEditForm {
    return {
      title: entry.title ?? '',
      notes: entry.notes ?? '',
      due: entry.due ?? '',
      today: entry.today,
      priority: entry.priority ?? '',
      assignee: entry.assignee ?? 'user',
      status: entry.status,
      ...overrides
    };
  }

  it('sends nothing at all when nothing changed — a Save must not rewrite untouched fields', () => {
    expect(taskEditPatch(entry, seed())).toEqual({});
  });

  it('sends ONLY the changed fields, so mutate_task round-trips every key Valea does not know', () => {
    expect(taskEditPatch(entry, seed({ priority: 'low' }))).toEqual({ priority: 'low' });
    expect(taskEditPatch(entry, seed({ today: false }))).toEqual({ today: false });
    expect(taskEditPatch(entry, seed({ status: 'done' }))).toEqual({ status: 'done' });
  });

  // Review round 1, L8: title used to be the one field that cleared to `""`.
  it('clears EVERY optional text field to null, title included', () => {
    expect(taskEditPatch(entry, seed({ title: '' }))).toEqual({ title: null });
    expect(taskEditPatch(entry, seed({ title: '   ' }))).toEqual({ title: null });
    expect(taskEditPatch(entry, seed({ notes: '' }))).toEqual({ notes: null });
    expect(taskEditPatch(entry, seed({ due: '' }))).toEqual({ due: null });
    expect(taskEditPatch(entry, seed({ priority: '' }))).toEqual({ priority: null });
  });

  it('trims the title, and treats a whitespace-only edit of an unchanged title as no edit', () => {
    expect(taskEditPatch(entry, seed({ title: '  Send the offer  ' }))).toEqual({});
    expect(taskEditPatch(entry, seed({ title: '  Send it today  ' }))).toEqual({ title: 'Send it today' });
  });

  it('compares assignee against the same default the select shows, so opening and saving is a no-op', () => {
    const unassigned = task({ assignee: undefined });
    expect(taskEditPatch(unassigned, { ...seed(), assignee: 'user' }).assignee).toBeUndefined();
    expect(taskEditPatch(unassigned, { ...seed(), assignee: 'agent' })).toMatchObject({ assignee: 'agent' });
  });

  it('normalizes an unknown status on save — the spec’s repair affordance', () => {
    const odd = task({ status: 'waiting_on_bank' });
    expect(taskEditPatch(odd, { ...seed(), status: 'open' })).toMatchObject({ status: 'open' });
  });
});

// The fixture itself is the "TasksTab renders the payload" pin: every row the
// tab must draw resolves to a decision, and the two degenerate entries get
// their notes rather than silently-dead controls.
describe('the fixture payload, end to end', () => {
  it('produces a row decision for every entry, including the degenerate ones', () => {
    expect(ledgerNote(FIXTURE.status)).toBeNull();
    expect(duplicateIdNote(FIXTURE.tasks)).not.toBeNull();

    const idLess = FIXTURE.tasks.find((t) => t.id === null);
    expect(idLess).toBeDefined();

    const unknown = FIXTURE.tasks.find((t) => t.status === 'waiting_on_bank');
    expect(unknown).toBeDefined();
    expect(statusLabel(unknown!.status)).toBe('waiting_on_bank');

    const first = FIXTURE.tasks[0];
    expect(showsAgentBadge(first)).toBe(true);
    expect(dueChip(first, TODAY)).toEqual({ text: 'due today', tone: 'today' });
    expect(taskSourceRender(first.source!, FIXTURE.mountKey)).toMatchObject({ kind: 'mail' });
  });
});
