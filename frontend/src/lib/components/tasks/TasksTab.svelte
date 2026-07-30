<script lang="ts">
  // The Tasks tab: every enabled ICM's ledger, merged and grouped by ICM with
  // the cockpit's provenance-header shape, default-filtered to Today.
  //
  // Reads `tasksStore` directly rather than taking the whole ledger through
  // props (the `ChatView`/`sessionsListStore` precedent) — the route stays thin
  // and there is exactly one copy of the merged ledger in the app.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { FilterPill, EmptyState } from '$lib/components/shell';
  import { mountProvenanceLabel } from '$lib/shell/provenance';
  import ListTodo from '@lucide/svelte/icons/list-todo';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import { applyTaskFilters, isCompleted, type TaskEntry, type TaskFilters } from '$lib/tasks/filters';
  import { duplicateIdNote, ledgerNote, repairFields, taskErrorMessage } from './task-shapes';
  import QuickAdd from './QuickAdd.svelte';
  import TaskRow from './TaskRow.svelte';
  import TaskEditor from './TaskEditor.svelte';

  let {
    /** Local calendar date (`YYYY-MM-DD`) the Today filter compares against — the route owns "what day is it". */
    todayIso,
    /** MRU mount key from `lib/today/quick-session.ts`, the quick-add picker's default. */
    defaultMountKey
  }: {
    todayIso: string;
    defaultMountKey: string | null;
  } = $props();

  let filters = $state<TaskFilters>({ view: 'today', assignee: null, status: null });
  let quickMountKey = $state('');
  let quickBusy = $state(false);
  let quickError = $state<string | null>(null);
  let rowError = $state<string | null>(null);
  let busyTaskId = $state<string | null>(null);
  let clearing = $state<string | null>(null);

  /** `(mountKey, id)` — the addressing every piece of ICM content uses. */
  let editing = $state<{ mountKey: string; taskId: string } | null>(null);
  let editorSaving = $state(false);
  let editorError = $state<string | null>(null);

  const icms = $derived(tasksStore.taskIcms);
  const pickerIcms = $derived(icms.map((icm) => ({ mountKey: icm.mountKey, icmName: icm.icmName })));

  // Seeds the picker from the MRU once the ledger list arrives, and repairs it
  // if the selected ICM disappears (unmounted mid-session).
  $effect(() => {
    const keys = icms.map((icm) => icm.mountKey);
    if (keys.length === 0) return;
    if (!keys.includes(quickMountKey)) {
      quickMountKey = defaultMountKey !== null && keys.includes(defaultMountKey) ? defaultMountKey : keys[0];
    }
  });

  const editingTask = $derived.by((): TaskEntry | null => {
    if (editing === null) return null;
    const icm = icms.find((candidate) => candidate.mountKey === editing!.mountKey);
    return icm?.tasks.find((task) => task.id === editing!.taskId) ?? null;
  });

  function rowsFor(icm: TaskIcm): TaskEntry[] {
    return applyTaskFilters(icm.tasks, filters, todayIso);
  }

  const visibleCount = $derived(icms.reduce((total, icm) => total + rowsFor(icm).length, 0));
  const anyCompleted = $derived(icms.some((icm) => icm.tasks.some(isCompleted)));

  /** Chip counts are computed against the whole ledger, so a chip never promises rows the click won't show. */
  const allTasks = $derived(icms.flatMap((icm) => icm.tasks));

  function statusCount(status: string): number {
    return allTasks.filter((task) => task.status === status).length;
  }

  function report(outcome: { ok: true } | { ok: false; error: string }): boolean {
    rowError = outcome.ok ? null : taskErrorMessage(outcome.error);
    return outcome.ok;
  }

  async function toggleDone(mountKey: string, task: TaskEntry): Promise<void> {
    if (task.id === null) return;
    busyTaskId = task.id;
    try {
      report(await tasksStore.setTaskStatus(mountKey, task.id, isCompleted(task) ? 'open' : 'done'));
    } finally {
      busyTaskId = null;
    }
  }

  async function drop(mountKey: string, task: TaskEntry): Promise<void> {
    if (task.id === null) return;
    report(await tasksStore.setTaskStatus(mountKey, task.id, 'dropped'));
  }

  /**
   * Row "Archive": completes the entry (as `dropped` when it is still open) and
   * then runs the archive sweep for THAT ICM. `archive_done` is per-ICM by
   * design — Valea owns archival, and there is no per-entry archive RPC — so
   * this also archives any other already-completed entries in the same ICM.
   * That is the same sweep "Clear done" performs, scoped by where the user
   * clicked; nothing open is ever touched (the sweep only takes
   * `done`/`dropped`).
   */
  async function archive(mountKey: string, task: TaskEntry): Promise<void> {
    if (task.id === null) return;
    if (!isCompleted(task) && !report(await tasksStore.setTaskStatus(mountKey, task.id, 'dropped'))) return;
    report(await tasksStore.clearDone(mountKey));
  }

  /** The id-less repair affordance: copy the entry's fields into a properly stamped task. */
  async function repair(mountKey: string, task: TaskEntry): Promise<void> {
    report(await tasksStore.createTask(mountKey, repairFields(task)));
  }

  async function quickAdd(mountKey: string, title: string): Promise<void> {
    quickBusy = true;
    quickError = null;
    try {
      const outcome = await tasksStore.createTask(mountKey, { title });
      if (!outcome.ok) quickError = taskErrorMessage(outcome.error);
    } finally {
      quickBusy = false;
    }
  }

  async function clearDone(mountKey: string | null): Promise<void> {
    clearing = mountKey ?? '*';
    try {
      report(await tasksStore.clearDone(mountKey));
    } finally {
      clearing = null;
    }
  }

  async function saveEdit(patch: Record<string, unknown>): Promise<void> {
    if (editing === null) return;
    editorSaving = true;
    editorError = null;
    try {
      const outcome = await tasksStore.patchTask(editing.mountKey, editing.taskId, patch);
      if (!outcome.ok) {
        editorError = taskErrorMessage(outcome.error);
        return;
      }
      editing = null;
    } finally {
      editorSaving = false;
    }
  }
</script>

{#if icms.length === 0}
  <EmptyState
    icon={ListTodo}
    title="No projects yet"
    body="Tasks live in a tasks.json file at the root of each project. Mount or create a project first and the ledger appears here."
  />
{:else}
  <div class="flex flex-col gap-4">
    <QuickAdd
      icms={pickerIcms}
      bind:mountKey={quickMountKey}
      busy={quickBusy}
      error={quickError}
      onAdd={(mountKey, title) => void quickAdd(mountKey, title)}
    />

    <div class="flex flex-wrap items-center gap-1" role="tablist" aria-label="Task filters">
      <FilterPill
        label="Today"
        active={filters.view === 'today'}
        onclick={() => (filters = { ...filters, view: 'today' })}
      />
      <FilterPill label="All" active={filters.view === 'all'} onclick={() => (filters = { ...filters, view: 'all' })} />
      <span class="bg-paper-hairline mx-1 h-4 w-px" aria-hidden="true"></span>
      <FilterPill
        label="Anyone"
        active={filters.assignee === null}
        onclick={() => (filters = { ...filters, assignee: null })}
      />
      <FilterPill
        label="Me"
        active={filters.assignee === 'user'}
        onclick={() => (filters = { ...filters, assignee: 'user' })}
      />
      <FilterPill
        label="Agent"
        active={filters.assignee === 'agent'}
        onclick={() => (filters = { ...filters, assignee: 'agent' })}
      />
      <span class="bg-paper-hairline mx-1 h-4 w-px" aria-hidden="true"></span>
      <FilterPill
        label="Any status"
        active={filters.status === null}
        onclick={() => (filters = { ...filters, status: null })}
      />
      <FilterPill
        label="In progress"
        count={statusCount('in_progress')}
        active={filters.status === 'in_progress'}
        onclick={() => (filters = { ...filters, status: 'in_progress' })}
      />
      <FilterPill
        label="Done"
        count={statusCount('done')}
        active={filters.status === 'done'}
        onclick={() => (filters = { ...filters, status: 'done' })}
      />
    </div>

    {#if rowError}
      <p class="text-warn-ink text-[12.5px]" role="alert">{rowError}</p>
    {/if}

    {#if anyCompleted}
      <div>
        <Button
          type="button"
          variant="outline"
          size="sm"
          disabled={clearing !== null}
          onclick={() => void clearDone(null)}
        >
          Clear done everywhere
        </Button>
      </div>
    {/if}

    <div class="flex flex-col gap-7">
      {#each icms as icm (icm.mountKey)}
        {@const rows = rowsFor(icm)}
        {@const note = ledgerNote(icm.status)}
        {@const duplicates = duplicateIdNote(icm.tasks)}
        <section>
          <div class="flex items-baseline justify-between gap-3">
            <span class="text-ink-meta text-[12px]">
              {mountProvenanceLabel(icm.icmName) ?? `· ${icm.mountKey}`}
            </span>
            {#if icm.tasks.some(isCompleted)}
              <button
                type="button"
                disabled={clearing !== null}
                onclick={() => void clearDone(icm.mountKey)}
                class="text-ink-meta hover:text-ink-heading text-[11.5px] hover:underline"
              >
                Clear done
              </button>
            {/if}
          </div>

          {#if note}
            <!-- Calm, per the leniency contract: tasks.json is the user's file,
                 and an unparseable one is a thing to fix, not an app error. -->
            <p class="text-ink-meta mt-1.5 text-[12.5px]">tasks.json is {note}</p>
          {/if}

          {#if duplicates}
            <p class="text-ink-meta mt-1.5 text-[12.5px]">{duplicates}</p>
          {/if}

          {#if rows.length === 0}
            {#if icm.status === 'ok' && icm.tasks.length > 0}
              <p class="text-ink-meta mt-1.5 text-[12.5px]">Nothing matches this filter here.</p>
            {:else if icm.status !== 'unreadable'}
              <p class="text-ink-meta mt-1.5 text-[12.5px]">No tasks yet.</p>
            {/if}
          {:else}
            <ul class="mt-1.5 flex flex-col">
              {#each rows as task, index (task.id ?? `no-id-${index}`)}
                <TaskRow
                  {task}
                  mountKey={icm.mountKey}
                  {todayIso}
                  busy={task.id !== null && busyTaskId === task.id}
                  selected={editing?.mountKey === icm.mountKey && editing?.taskId === task.id}
                  onToggleDone={() => void toggleDone(icm.mountKey, task)}
                  onOpen={() => {
                    if (task.id === null) return;
                    editorError = null;
                    editing = { mountKey: icm.mountKey, taskId: task.id };
                  }}
                  onDrop={() => void drop(icm.mountKey, task)}
                  onArchive={() => void archive(icm.mountKey, task)}
                  onRepair={() => void repair(icm.mountKey, task)}
                />
              {/each}
            </ul>
          {/if}
        </section>
      {/each}
    </div>

    {#if visibleCount === 0 && filters.view === 'today'}
      <p class="text-ink-body text-[13px]">
        Nothing due, overdue, or flagged for today. The
        <button type="button" class="underline" onclick={() => (filters = { ...filters, view: 'all' })}>All</button>
        filter shows the whole backlog.
      </p>
    {/if}
  </div>
{/if}

<Dialog.Root
  open={editingTask !== null}
  onOpenChange={(open) => {
    if (!open) editing = null;
  }}
>
  <Dialog.Content class="sm:max-w-md">
    {#if editingTask}
      <!-- Keyed on the addressed task so the editor's local field state is
           re-seeded when a different row is opened, but NOT on every re-list
           (which replaces the entry object while the dialog is open). -->
      {#key `${editing?.mountKey}/${editing?.taskId}`}
        <TaskEditor
          task={editingTask}
          saving={editorSaving}
          error={editorError}
          onSave={(patch) => void saveEdit(patch)}
          onClose={() => (editing = null)}
        />
      {/key}
    {/if}
  </Dialog.Content>
</Dialog.Root>
