<script lang="ts">
  // The Tasks tab: every enabled ICM's ledger, merged, narrowed by the persisted
  // controls row, and grouped by project / priority / due date.
  //
  // Reads `tasksStore` and `tasksSettings` directly rather than taking either
  // through props (the `ChatView`/`sessionsListStore` precedent) — the route
  // stays thin, there is exactly one copy of the merged ledger in the app, and
  // exactly one owner of the filter state that outlives the page.
  //
  // What is persisted and what is not (spec §Persistence): the four filter axes
  // — mode, view, assignee, group-by — live in `tasksSettings` and survive a
  // reload; the search box and the per-section "Show done" expansions are
  // session-local `$state` here, because a filter you cannot see on return is a
  // filter that makes the app look broken, and neither of those two is visible
  // in the controls row after a reload.
  //
  // The old status SegmentedControl is gone (spec: the board covers status
  // browsing, done rows fold behind their section footer). `applyTaskFilters`
  // keeps its `status` axis for compatibility and is passed `null`.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { NativeSelect } from '$lib/components/ui/native-select/index.js';
  import { EmptyState, SegmentedControl } from '$lib/components/shell';
  import ListTodo from '@lucide/svelte/icons/list-todo';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import { tasksSettings } from '$lib/tasks/settings.svelte';
  import type { TasksGroupBy } from '$lib/tasks/settings';
  import {
    applyTaskFilters,
    groupByDue,
    groupByPriority,
    isCompleted,
    matchesSearch,
    nextUp,
    orderTaskRows,
    splitOverdue,
    todayFilter,
    type TaskEntry
  } from '$lib/tasks/filters';
  import { duplicateIdNote, ledgerNote, repairFields, rowKeys, taskErrorMessage } from './task-shapes';
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

  /** One rendered line: the entry, the ledger it came from, and a key no twin can collide with. */
  type Row = { key: string; icm: TaskIcm; task: TaskEntry };

  /**
   * One rendered section. `icm` is set for project sections only — "Clear done"
   * archives a MOUNT's ledger, and a priority bucket spans mounts.
   */
  type Section = {
    key: string;
    label: string;
    icm: TaskIcm | null;
    /** `groupByDue`'s own overdue bucket: it IS the overdue group, so it takes no nested overdue header. */
    overdueBucket: boolean;
    /** Calm per-ledger notes (unreadable file, duplicate ids) — project sections only. */
    notes: string[];
    open: TaskEntry[];
    done: TaskEntry[];
  };

  let search = $state('');
  /** `search` after ~150ms of quiet — what actually narrows the list, so a fast typist doesn't re-filter per keystroke. */
  let debounced = $state('');
  /**
   * Section keys whose done rows are unfolded. A `Set` inside `$state` is NOT
   * proxied by Svelte (that is `SvelteSet`'s job), so this is always REPLACED,
   * never mutated in place — mutation would update nothing.
   */
  let showDone = $state<Set<string>>(new Set());

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

  const filters = $derived(tasksSettings.filters);
  const icms = $derived(tasksStore.taskIcms);
  const pickerIcms = $derived(icms.map((icm) => ({ mountKey: icm.mountKey, icmName: icm.icmName })));

  $effect(() => {
    const query = search;
    const timer = setTimeout(() => (debounced = query), 150);
    return () => clearTimeout(timer);
  });

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

  /** The assignee axis alone, for the counts — `null` is "everyone", and an absent `assignee` reads as the user's. */
  function assigneeNarrow(rows: TaskEntry[]): TaskEntry[] {
    return rows.filter((task) => filters.assignee === null || (task.assignee ?? 'user') === filters.assignee);
  }

  // Segment counts are computed over the merged ledgers with the CURRENT
  // assignee filter applied and the SEARCH IGNORED: a segment must never promise
  // rows its click won't show, and search is transient narrowing inside a view,
  // not a view of its own (a count that moved while you typed would be noise).
  const todayCount = $derived(assigneeNarrow(icms.flatMap((icm) => todayFilter(icm.tasks, todayIso))).length);
  // OPEN tasks only. The All view still SHOWS done rows — folded behind each
  // section's footer — but a count that included them would promise rows a click
  // hides, and archived-pending work is not what "All · 12" is read as.
  const allCount = $derived(assigneeNarrow(icms.flatMap((icm) => icm.tasks.filter((task) => !isCompleted(task)))).length);

  /** Every entry in every ledger → its project. The one place a bare `TaskEntry` is resolved back to a mount. */
  const ownerOf = $derived.by(() => {
    const map = new Map<TaskEntry, TaskIcm>();
    for (const icm of icms) for (const task of icm.tasks) map.set(task, icm);
    return map;
  });

  /** The view + assignee + search pass, per ledger — every list below is a regrouping of exactly these rows. */
  const perIcm = $derived(
    icms.map((icm) => ({
      icm,
      tasks: applyTaskFilters(
        icm.tasks,
        { view: filters.view, assignee: filters.assignee, status: null },
        todayIso
      ).filter((task) => matchesSearch(task, debounced))
    }))
  );

  const filteredTasks = $derived(perIcm.flatMap((entry) => entry.tasks));

  /** The calm per-ledger notes, verbatim from `task-shapes` — an unreadable file and duplicate ids both stay visible. */
  function noteLines(icm: TaskIcm): string[] {
    const lines: string[] = [];
    const note = ledgerNote(icm.status);
    if (note !== null) lines.push(`tasks.json is ${note}`);
    const duplicates = duplicateIdNote(icm.tasks);
    if (duplicates !== null) lines.push(duplicates);
    return lines;
  }

  /**
   * Grouping. `project` keeps the per-ICM sections; `priority` and `due` regroup
   * the flattened rows, re-sorted as ONE list first — `perIcm` arrives
   * ICM-major, and a "High" bucket ordered by project is not ordered at all.
   *
   * Done/dropped rows are split off in every grouping rather than dropped: they
   * fold behind the section footer, which is the only place "Clear done" lives.
   */
  const sections = $derived.by((): Section[] => {
    if (filters.groupBy === 'project') {
      return perIcm.map(({ icm, tasks }) => ({
        key: `project:${icm.mountKey}`,
        label: icm.icmName || icm.mountKey,
        icm,
        overdueBucket: false,
        notes: noteLines(icm),
        open: tasks.filter((task) => !isCompleted(task)),
        done: tasks.filter(isCompleted)
      }));
    }

    const flat = orderTaskRows(filteredTasks);
    const groups = filters.groupBy === 'priority' ? groupByPriority(flat) : groupByDue(flat, todayIso);
    return groups.map((group) => ({
      key: `${filters.groupBy}:${group.key}`,
      label: group.label,
      icm: null,
      overdueBucket: filters.groupBy === 'due' && group.key === 'overdue',
      notes: [],
      open: group.rows.filter((task) => !isCompleted(task)),
      done: group.rows.filter(isCompleted)
    }));
  });

  /**
   * A section renders when it has rows or something to say. An ICM with nothing
   * in it stays quiet — the per-section "No tasks yet." note is gone, because a
   * page listing six projects repeated it six times and said nothing.
   */
  const visibleSections = $derived(
    sections.filter((section) => section.open.length > 0 || section.done.length > 0 || section.notes.length > 0)
  );

  /** Grouped by priority or due date, the ledger notes have no section to sit under — they get one quiet block. */
  const strayNotes = $derived(
    filters.groupBy === 'project'
      ? []
      : icms
          .map((icm) => ({ mountKey: icm.mountKey, name: icm.icmName || icm.mountKey, notes: noteLines(icm) }))
          .filter((entry) => entry.notes.length > 0)
  );

  /**
   * The empty Today view is never blank (spec §Day planning): it offers the top
   * of the backlog, each row one click from today. Fed the assignee-narrowed
   * ledgers, so "Mine" doesn't suggest the assistant's work; `nextUp` itself
   * drops completed entries and anything the Today view already holds.
   */
  const nextUpTasks = $derived.by(() => {
    if (filters.view !== 'today' || filteredTasks.length > 0 || debounced.trim() !== '') return [];
    return nextUp(assigneeNarrow(icms.flatMap((icm) => icm.tasks)), todayIso, 5);
  });

  /** Attaches each entry to its project and stamps collision-free `#each` keys (see `rowKeys`). */
  function toRows(tasks: TaskEntry[]): Row[] {
    const owned = tasks.flatMap((task) => {
      const icm = ownerOf.get(task);
      return icm === undefined ? [] : [{ icm, task }];
    });
    const keys = rowKeys(owned.map(({ icm, task }) => ({ mountKey: icm.mountKey, id: task.id })));
    return owned.map((row, index) => ({ key: keys[index], ...row }));
  }

  function toggleShowDone(key: string): void {
    const next = new Set(showDone);
    if (!next.delete(key)) next.add(key);
    showDone = next;
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

  /** The row's one-click triage: flip the `today` flag without opening the editor. */
  async function toggleToday(mountKey: string, task: TaskEntry): Promise<void> {
    if (task.id === null) return;
    report(await tasksStore.patchTask(mountKey, task.id, { today: !task.today }));
  }

  async function drop(mountKey: string, task: TaskEntry): Promise<void> {
    if (task.id === null) return;
    report(await tasksStore.setTaskStatus(mountKey, task.id, 'dropped'));
  }

  /** The id-less repair affordance: copy the entry's fields into a properly stamped task. */
  async function repair(mountKey: string, task: TaskEntry): Promise<void> {
    report(await tasksStore.createTask(mountKey, repairFields(task)));
  }

  function openEditor(mountKey: string, task: TaskEntry): void {
    if (task.id === null) return;
    editorError = null;
    editing = { mountKey, taskId: task.id };
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
  // archiving is gone — each project's footer owns its own sweep.
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
</script>

{#snippet rowList(rows: Row[], tagged: boolean)}
  <ul class="mt-1.5 flex flex-col">
    {#each rows as row (row.key)}
      <TaskRow
        task={row.task}
        mountKey={row.icm.mountKey}
        {todayIso}
        projectTag={tagged ? row.icm.icmName || row.icm.mountKey : null}
        busy={row.task.id !== null && busyTaskId === row.task.id}
        selected={editing?.mountKey === row.icm.mountKey && editing?.taskId === row.task.id}
        sessionLive={null}
        onToggleDone={() => void toggleDone(row.icm.mountKey, row.task)}
        onToggleToday={() => void toggleToday(row.icm.mountKey, row.task)}
        onOpen={() => openEditor(row.icm.mountKey, row.task)}
        onDrop={() => void drop(row.icm.mountKey, row.task)}
        onRepair={() => void repair(row.icm.mountKey, row.task)}
      />
    {/each}
  </ul>
{/snippet}

{#if icms.length === 0}
  <EmptyState
    icon={ListTodo}
    title="No projects yet"
    body="Each project keeps its own task list, in a plain file you can always open yourself. Add a project from the sidebar and the list appears here."
  />
{:else}
  <div class="flex flex-col gap-4">
    <div class="flex flex-wrap items-center gap-2">
      <SegmentedControl
        label="List or board"
        size="sm"
        value={filters.mode}
        options={[
          { value: 'list', label: 'List' },
          { value: 'board', label: 'Board' }
        ]}
        onChange={(mode) => tasksSettings.setFilters({ mode: mode === 'board' ? 'board' : 'list' })}
      />
      <SegmentedControl
        label="Which tasks"
        value={filters.view}
        options={[
          { value: 'today', label: 'Today', count: todayCount },
          { value: 'all', label: 'All', count: allCount }
        ]}
        onChange={(view) => tasksSettings.setFilters({ view: view === 'all' ? 'all' : 'today' })}
      />
      <SegmentedControl
        label="Whose tasks"
        value={filters.assignee ?? 'anyone'}
        options={[
          { value: 'user', label: 'Mine' },
          { value: 'agent', label: "Assistant's" },
          { value: 'anyone', label: 'Everyone' }
        ]}
        onChange={(assignee) =>
          tasksSettings.setFilters({ assignee: assignee === 'user' || assignee === 'agent' ? assignee : null })}
      />

      {#if filters.mode === 'list'}
        <!-- Group-by is a LIST concept: the board is status-grouped by definition. -->
        <label class="text-ink-meta text-[11.5px]" for="tasks-group-by">Group</label>
        <!-- A get/set binding, not a local mirror: the store IS the value, and
             a second copy of a persisted axis is the bug that makes a reload
             disagree with the control. -->
        <NativeSelect
          id="tasks-group-by"
          bind:value={() => filters.groupBy, (value) => tasksSettings.setFilters({ groupBy: value as TasksGroupBy })}
          class="w-auto"
        >
          <option value="project">Project</option>
          <option value="priority">Priority</option>
          <option value="due">Due date</option>
        </NativeSelect>
      {/if}

      <Input
        type="search"
        bind:value={search}
        placeholder="Search tasks…"
        aria-label="Search tasks"
        class="ml-auto w-[200px]"
      />
    </div>

    {#if rowError}
      <p class="text-warn-ink text-[12.5px]" role="alert">{rowError}</p>
    {/if}

    <div class="flex flex-col gap-2">
      <QuickAdd
        icms={pickerIcms}
        bind:mountKey={quickMountKey}
        busy={quickBusy}
        error={quickError}
        onAdd={(mountKey, title) => void quickAdd(mountKey, title)}
      />

      {#if filters.mode === 'board'}
        <!-- Task 9 replaces this line with the board itself; the toggle is
             honest about where it goes rather than rendering dead furniture. -->
        <p class="text-ink-meta text-[13px]">Board view is coming next.</p>
      {:else}
        {#if strayNotes.length > 0}
          <!-- Grouped by priority or due date there are no project sections, so
               the leniency notes say which ledger they are about. -->
          <div class="flex flex-col gap-1 pt-2">
            {#each strayNotes as entry (entry.mountKey)}
              {#each entry.notes as note (note)}
                <p class="text-ink-meta text-[12.5px]">{entry.name}: {note}</p>
              {/each}
            {/each}
          </div>
        {/if}

        <div class="flex flex-col gap-7 pt-2">
          {#each visibleSections as section (section.key)}
            {@const split = splitOverdue(section.open, todayIso)}
            {@const expanded = showDone.has(section.key)}
            {@const tagged = filters.groupBy !== 'project'}
            <!-- The mount whose ledger "Clear done" sweeps — a project section
                 has one, a priority or due bucket spans mounts and has none. -->
            {@const clearMount = section.icm === null ? null : section.icm.mountKey}
            {@const ledgerDone = section.icm === null ? 0 : section.icm.tasks.filter(isCompleted).length}
            <section>
              <div class="flex items-baseline gap-2">
                <h2 class="text-overline">{section.label}</h2>
                {#if section.open.length > 0}
                  <span class="text-ink-meta text-[11.5px] tabular-nums">{section.open.length}</span>
                {/if}
              </div>

              {#each section.notes as note (note)}
                <!-- Calm, per the leniency contract: tasks.json is the user's file,
                     and an unparseable one is a thing to fix, not an app error. -->
                <p class="text-ink-meta mt-1.5 text-[12.5px]">{note}</p>
              {/each}

              {#if split.overdue.length > 0}
                {#if !section.overdueBucket}
                  <!-- Overdue first, in every group — the one thing that reorders
                       a list on its own. Inside the Due-date grouping's own
                       Overdue bucket the header would name itself, so it doesn't. -->
                  <h3 class="text-overline text-warn-ink mt-2.5">Overdue · {split.overdue.length}</h3>
                {/if}
                {@render rowList(toRows(split.overdue), tagged)}
              {/if}

              {#if split.rest.length > 0}
                {@render rowList(toRows(split.rest), tagged)}
              {/if}

              {#if expanded && section.done.length > 0}
                {@render rowList(toRows(section.done), tagged)}
              {/if}

              {#if section.done.length > 0}
                <!-- Every group carries one of these, so the visible words
                     ("Show", "Clear done") repeat down the page — the labels
                     name the section, which is what a screen reader is left
                     with when the header two lines up is out of reach. -->
                <div class="text-ink-meta mt-1.5 flex flex-wrap items-center gap-1.5 text-[11.5px]">
                  <span class="tabular-nums">{section.done.length} done</span>
                  <span aria-hidden="true">·</span>
                  <button
                    type="button"
                    aria-expanded={expanded}
                    aria-label={`${expanded ? 'Hide' : 'Show'} done tasks in ${section.label}`}
                    class="hover:text-ink-heading hover:underline"
                    onclick={() => toggleShowDone(section.key)}
                  >
                    {expanded ? 'Hide' : 'Show'}
                  </button>
                  {#if clearMount !== null && confirmingClear !== clearMount}
                    <span aria-hidden="true">·</span>
                    <button
                      type="button"
                      disabled={clearing !== null}
                      aria-label={`Clear done tasks in ${section.label}`}
                      onclick={() => (confirmingClear = clearMount)}
                      class="hover:text-ink-heading hover:underline"
                    >
                      Clear done
                    </button>
                  {/if}
                </div>
              {/if}

              {#if clearMount !== null && confirmingClear === clearMount}
                <!-- The card counts the LEDGER, not the fold: archiving sweeps
                     every done entry in the file, including ones the current
                     filters are hiding. -->
                <div
                  class="border-paper-border bg-paper-card shadow-card mt-1.5 flex flex-wrap items-center gap-2 rounded-[12px] border p-2.5"
                >
                  <p class="text-ink-body flex-1 text-[12.5px]">
                    Archive {ledgerDone === 1 ? 'the finished task' : `${ledgerDone} finished tasks`} in
                    {section.label}? They move to this project's archive file.
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
                    onclick={() => void clearDone(clearMount)}
                    disabled={clearing !== null}
                  >
                    Archive
                  </Button>
                </div>
              {/if}
            </section>
          {/each}
        </div>

        <!-- ONE message for the whole filtered view. -->
        {#if filteredTasks.length === 0}
          {#if debounced.trim() !== ''}
            <p class="text-ink-body pt-2 text-[13px]">No tasks match "{debounced.trim()}".</p>
          {:else if filters.view === 'today'}
            <!-- The empty Today view is a plan, not a void: the top of the
                 backlog, each row one Today click from becoming the day's. -->
            <div class="pt-2">
              {#if nextUpTasks.length > 0}
                <h2 class="text-overline">Next up</h2>
                {@render rowList(toRows(nextUpTasks), true)}
              {/if}
              <p class="text-ink-body mt-2.5 text-[13px]">
                Nothing due, overdue, or flagged for today — pick from the backlog above, or see
                <button type="button" class="underline" onclick={() => tasksSettings.setFilters({ view: 'all' })}>All</button>.
              </p>
            </div>
          {:else if filters.assignee !== null}
            <p class="text-ink-body pt-2 text-[13px]">
              Nothing matches these filters.
              <button type="button" class="underline" onclick={() => tasksSettings.setFilters({ assignee: null })}>
                Show everyone
              </button>
            </p>
          {:else}
            <p class="text-ink-body pt-2 text-[13px]">No tasks yet — add one above.</p>
          {/if}
        {/if}
      {/if}
    </div>
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
