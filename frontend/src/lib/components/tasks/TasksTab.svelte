<script lang="ts">
  // The Tasks tab: every enabled ICM's ledger, merged and grouped by ICM with
  // the cockpit's provenance-header shape, default-filtered to Today.
  //
  // Reads `tasksStore` directly rather than taking the whole ledger through
  // props (the `ChatView`/`sessionsListStore` precedent) — the route stays thin
  // and there is exactly one copy of the merged ledger in the app.
  //
  // The three filter axes are three `SegmentedControl`s, one track each —
  // the app's one pill grammar (critique P1: the old flat `FilterPill` row
  // painted the track color on its ACTIVE pill, inverting the segmented
  // control's vocabulary two rows above it, and its axis dividers measured
  // ~1.03:1). A mutually-exclusive set is a segmented control, full stop.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { EmptyState, SegmentedControl } from '$lib/components/shell';
  import ListTodo from '@lucide/svelte/icons/list-todo';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import {
    applyTaskFilters,
    countByStatus,
    isCompleted,
    type TaskEntry,
    type TaskFilters
  } from '$lib/tasks/filters';
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
  /** The ICM whose "Clear done" is awaiting its inline confirmation. */
  let confirmingClear = $state<string | null>(null);

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
  const otherFiltersActive = $derived(filters.assignee !== null || filters.status !== null);

  /**
   * Status counts over the CURRENT view's base (same view + assignee, status
   * open) — a segment must never promise rows its click won't show. The old
   * whole-ledger count did exactly that: "Done · 1" on the Today view clicked
   * through to zero rows (critique P-issue; the fix is the tested
   * `countByStatus` over the filtered base).
   */
  const statusBase = $derived(
    icms.flatMap((icm) => applyTaskFilters(icm.tasks, { ...filters, status: null }, todayIso))
  );

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

  /** The id-less repair affordance: copy the entry's fields into a properly stamped task. */
  async function repair(mountKey: string, task: TaskEntry): Promise<void> {
    report(await tasksStore.createTask(mountKey, repairFields(task)));
  }

  async function quickAdd(mountKey: string, title: string): Promise<void> {
    quickBusy = true;
    quickError = null;
    try {
      // Adding while the Today view is up means "for today" — without the flag
      // the brand-new task failed `todayFilter` and vanished the moment it was
      // created, under a line reading "nothing due today" (critique P1, the
      // worst first-run moment in the feature).
      const fields: Record<string, unknown> =
        filters.view === 'today' ? { title, today: true } : { title };
      const outcome = await tasksStore.createTask(mountKey, fields);
      if (!outcome.ok) quickError = taskErrorMessage(outcome.error);
    } finally {
      quickBusy = false;
    }
  }

  // Archival is per-ICM only, behind an inline confirmation that names the
  // count (critique P-issue: "Clear done everywhere" swept every project on one
  // unconfirmed click, with a near-twin control 40px below it). Cross-project
  // archiving is gone — each project's header owns its own sweep.
  async function clearDone(mountKey: string): Promise<void> {
    clearing = mountKey;
    try {
      if (report(await tasksStore.clearDone(mountKey))) confirmingClear = null;
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

  /** A section renders when it has rows or something to say — a filtered-empty ICM stays quiet and the single message below speaks. */
  function sectionVisible(icm: TaskIcm, rows: TaskEntry[]): boolean {
    if (rows.length > 0) return true;
    if (icm.status === 'unreadable') return true;
    if (duplicateIdNote(icm.tasks) !== null) return true;
    return icm.tasks.length === 0;
  }
</script>

{#if icms.length === 0}
  <EmptyState
    icon={ListTodo}
    title="No projects yet"
    body="Each project keeps its own task list, in a plain file you can always open yourself. Add a project from the sidebar and the list appears here."
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

    <div class="flex flex-wrap items-center gap-2">
      <SegmentedControl
        label="Which tasks"
        value={filters.view}
        options={[
          { value: 'today', label: 'Today' },
          { value: 'all', label: 'All' }
        ]}
        onChange={(view) => (filters = { ...filters, view: view as TaskFilters['view'] })}
      />
      <SegmentedControl
        label="Whose tasks"
        value={filters.assignee ?? 'anyone'}
        options={[
          { value: 'anyone', label: 'Anyone' },
          { value: 'user', label: 'Me' },
          { value: 'agent', label: 'Assistant' }
        ]}
        onChange={(assignee) =>
          (filters = { ...filters, assignee: assignee === 'anyone' ? null : (assignee as 'user' | 'agent') })}
      />
      <SegmentedControl
        label="Task status"
        value={filters.status ?? 'any'}
        options={[
          { value: 'any', label: 'Any status' },
          { value: 'in_progress', label: 'In progress', count: countByStatus(statusBase, 'in_progress') },
          { value: 'done', label: 'Done', count: countByStatus(statusBase, 'done') }
        ]}
        onChange={(status) => (filters = { ...filters, status: status === 'any' ? null : status })}
      />
    </div>

    {#if rowError}
      <p class="text-warn-ink text-[12.5px]" role="alert">{rowError}</p>
    {/if}

    <div class="flex flex-col gap-7">
      {#each icms as icm (icm.mountKey)}
        {@const rows = rowsFor(icm)}
        {@const note = ledgerNote(icm.status)}
        {@const duplicates = duplicateIdNote(icm.tasks)}
        {@const doneCount = icm.tasks.filter(isCompleted).length}
        {#if sectionVisible(icm, rows)}
          <section>
            <div class="flex items-baseline justify-between gap-3">
              <h2 class="text-overline">{icm.icmName || icm.mountKey}</h2>
              {#if doneCount > 0 && confirmingClear !== icm.mountKey}
                <button
                  type="button"
                  disabled={clearing !== null}
                  onclick={() => (confirmingClear = icm.mountKey)}
                  class="text-ink-meta hover:text-ink-heading text-[11.5px] hover:underline"
                >
                  Clear done
                </button>
              {/if}
            </div>

            {#if confirmingClear === icm.mountKey}
              <div
                class="border-paper-border bg-paper-card shadow-card mt-1.5 flex flex-wrap items-center gap-2 rounded-[12px] border p-2.5"
              >
                <p class="text-ink-body flex-1 text-[12.5px]">
                  Archive {doneCount === 1 ? 'the finished task' : `${doneCount} finished tasks`} in
                  {icm.icmName || icm.mountKey}? They move to this project's archive file.
                </p>
                <Button
                  type="button"
                  variant="ghost"
                  size="sm"
                  onclick={() => (confirmingClear = null)}
                  disabled={clearing !== null}
                >
                  Cancel
                </Button>
                <Button
                  type="button"
                  variant="outline"
                  size="sm"
                  onclick={() => void clearDone(icm.mountKey)}
                  disabled={clearing !== null}
                >
                  Archive
                </Button>
              </div>
            {/if}

            {#if note}
              <!-- Calm, per the leniency contract: tasks.json is the user's file,
                   and an unparseable one is a thing to fix, not an app error. -->
              <p class="text-ink-meta mt-1.5 text-[12.5px]">tasks.json is {note}</p>
            {/if}

            {#if duplicates}
              <p class="text-ink-meta mt-1.5 text-[12.5px]">{duplicates}</p>
            {/if}

            {#if rows.length === 0}
              {#if icm.status !== 'unreadable' && icm.tasks.length === 0}
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
                    onRepair={() => void repair(icm.mountKey, task)}
                  />
                {/each}
              </ul>
            {/if}
          </section>
        {/if}
      {/each}
    </div>

    <!-- ONE empty message for the whole filtered view — the per-section
         "nothing matches" note and this line used to render together,
         contradicting each other (critique P-issue). -->
    {#if visibleCount === 0}
      {#if otherFiltersActive}
        <p class="text-ink-body text-[13px]">
          Nothing matches these filters.
          <button
            type="button"
            class="underline"
            onclick={() => (filters = { view: 'all', assignee: null, status: null })}
          >
            Show everything
          </button>
        </p>
      {:else if filters.view === 'today'}
        <p class="text-ink-body text-[13px]">
          Nothing due, overdue, or flagged for today. The
          <button type="button" class="underline" onclick={() => (filters = { ...filters, view: 'all' })}>All</button>
          filter shows the whole backlog.
        </p>
      {/if}
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
      <Dialog.Title class="text-ink-heading text-[14px] font-semibold">Edit task</Dialog.Title>
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
