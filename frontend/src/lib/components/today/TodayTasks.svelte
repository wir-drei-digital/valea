<script lang="ts">
  // Today's tasks (redesign spec §Today's tasks) — the day's real work, read
  // from the LEDGERS through `tasksStore` rather than from the cockpit payload's
  // summary line. That is what makes the rows live: the checkbox completes a
  // task in place, the title opens the shared editor, and the Tasks page and
  // this one are looking at the same file through the same store.
  //
  // The split with the route (brief step 3): the ROUTE computes `merged` — the
  // today view, merged across ledgers, narrowed by the assignee toggle and
  // ordered — because it needs `todayCount`/`overdueCount` for the header's
  // summary line and must not derive them a second way. This component renders
  // that list, owns the toggle (reading `tasksSettings` directly, the
  // `TasksTab`/`ChatView` precedent: one owner of state that outlives the page),
  // and writes through `tasksStore`.
  //
  // VISIBILITY IS THE ROUTE'S: it mounts this when some ledger still holds an
  // open task OR one of them is unreadable, so an empty `merged` here means
  // "nothing for today", never "nothing at all" — the whole-page welcome card
  // speaks for the latter. That is why the header and the toggle still render
  // with no rows: the way back from a toggle that hid everything has to stay on
  // screen, and an unreadable ledger has a note to show even with no rows at all.
  //
  // The row handlers below are COPIES of TasksTab's, not an extraction: they are
  // three to six lines each, they share the same store, and a "task row actions"
  // abstraction over two call sites would be harder to read than either.
  //
  // Not here, deliberately: `→ Assistant`. `TaskRow` renders no button when
  // `onHandOff` is absent, and hand-off belongs where the backlog is (spec
  // §Hand to assistant lives on the Tasks page). The `session` chip still links
  // a task that IS with the assistant back to its chat.
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { SegmentedControl } from '$lib/components/shell';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { tasksSettings } from '$lib/tasks/settings.svelte';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import {
    isCompleted,
    splitOverdue,
    todayFilter,
    type TaskEntry
  } from '$lib/tasks/filters';
  import { sessionLiveById } from '$lib/tasks/handoff';
  import { todayTailSegments, unreadableLedgerNotes } from '$lib/today/today-view';
  import {
    repairFields,
    rowKeys,
    taskErrorMessage,
    taskSession
  } from '$lib/components/tasks/task-shapes';
  import TaskRow from '$lib/components/tasks/TaskRow.svelte';
  import TaskEditor from '$lib/components/tasks/TaskEditor.svelte';

  let {
    /** The today view, merged across ledgers, assignee-narrowed and ordered — the route's derivation. */
    merged,
    /** Local calendar date (`YYYY-MM-DD`); the route owns "what day is it" and re-reads it at midnight. */
    todayIso
  }: {
    merged: { icm: TaskIcm; task: TaskEntry }[];
    todayIso: string;
  } = $props();

  /** One rendered line: the entry, the ledger it came from, and a key no twin can collide with. */
  type Row = { key: string; icm: TaskIcm; task: TaskEntry };

  let rowError = $state<string | null>(null);
  let busyTaskId = $state<string | null>(null);

  /** `(mountKey, id)` — the addressing every piece of ICM content uses. */
  let editing = $state<{ mountKey: string; taskId: string } | null>(null);
  let editorSaving = $state(false);
  let editorError = $state<string | null>(null);

  const icms = $derived(tasksStore.taskIcms);
  const mine = $derived(tasksSettings.todayAssignee === 'user');

  /**
   * Ledgers Valea could not parse. They contribute no rows, so without this the
   * section would be silent about tasks that exist in a broken file — and the
   * route's whole-page empty state would go further and call the day empty. The
   * route reads the same helper for that guard; one predicate, two surfaces.
   */
  const ledgerNotes = $derived(unreadableLedgerNotes(icms));

  /** Every merged entry → its project. The one place a bare `TaskEntry` is resolved back to a mount. */
  const ownerOf = $derived(new Map(merged.map(({ icm, task }) => [task, icm])));

  /** Overdue first, oldest due first (the warn group); the rest keep the route's order. */
  const split = $derived(splitOverdue(merged.map((row) => row.task), todayIso));

  /**
   * Count honesty (spec §Today's tasks): the header says `2 of 3 tasks` exactly
   * when the toggle is hiding rows. `total` is the today view WITHOUT the
   * assignee narrowing — the same set `merged` is drawn from, which is why it is
   * computed from the same `todayFilter` rather than from a stored number.
   */
  const total = $derived(icms.reduce((sum, icm) => sum + todayFilter(icm.tasks, todayIso).length, 0));
  const countLabel = $derived(
    `${merged.length < total ? `${merged.length} of ` : ''}${total} ${total === 1 ? 'task' : 'tasks'}`
  );

  /**
   * The tail line: what this section is NOT showing, and one link to go deal
   * with it. `backlogCount` is open work outside the today view (assignee-
   * narrowed like the list itself); `hiddenAssistantCount` is what `Mine` just
   * removed from today.
   *
   * Today-view membership is tested by OBJECT IDENTITY, never by `id`: ids are
   * nullable and duplicable under the leniency contract, and an id-keyed set
   * answers `has(null)` for every id-less entry (`nextUp`'s note in
   * `filters.ts`, which is the same trap).
   */
  const tail = $derived.by(() => {
    let backlogCount = 0;
    let hiddenAssistantCount = 0;
    for (const icm of icms) {
      const today = new Set(todayFilter(icm.tasks, todayIso));
      for (const task of icm.tasks) {
        if (today.has(task)) {
          if (mine && task.assignee === 'agent') hiddenAssistantCount += 1;
          continue;
        }
        if (isCompleted(task)) continue;
        if (mine && (task.assignee ?? 'user') !== 'user') continue;
        backlogCount += 1;
      }
    }
    return todayTailSegments({ backlogCount, hiddenAssistantCount });
  });

  const editingTask = $derived.by((): TaskEntry | null => {
    if (editing === null) return null;
    const icm = icms.find((candidate) => candidate.mountKey === editing!.mountKey);
    return icm?.tasks.find((task) => task.id === editing!.taskId) ?? null;
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

{#snippet rowList(rows: Row[])}
  <ul class="mt-1.5 flex flex-col">
    {#each rows as row (row.key)}
      <!-- The bound session's live dot, when the recency window still knows it:
           `sessionLiveById` answers `null` for an id that has aged out, and the
           chip then renders without a dot rather than claiming "ended". -->
      {@const session = taskSession(row.task)}
      <TaskRow
        task={row.task}
        mountKey={row.icm.mountKey}
        {todayIso}
        projectTag={row.icm.icmName || row.icm.mountKey}
        busy={row.task.id !== null && busyTaskId === row.task.id}
        selected={editing?.mountKey === row.icm.mountKey && editing?.taskId === row.task.id}
        sessionLive={session === null ? null : sessionLiveById(recentSessionsStore.groups, session)}
        onToggleDone={() => void toggleDone(row.icm.mountKey, row.task)}
        onToggleToday={() => void toggleToday(row.icm.mountKey, row.task)}
        onOpen={() => openEditor(row.icm.mountKey, row.task)}
        onDrop={() => void drop(row.icm.mountKey, row.task)}
        onRepair={() => void repair(row.icm.mountKey, row.task)}
      />
    {/each}
  </ul>
{/snippet}

<section>
  <div class="flex flex-wrap items-center gap-2">
    <h2 class="text-overline">Today</h2>
    <span class="text-ink-meta text-[11.5px] tabular-nums">{countLabel}</span>
    <div class="ml-auto">
      <!-- Two segments, not the Tasks page's three: Today is the day's own
           list, and "the assistant's work only" is a browsing question the
           Tasks page answers. `null` is "everyone" in the persisted shape. -->
      <SegmentedControl
        label="Whose tasks"
        size="sm"
        value={mine ? 'user' : 'anyone'}
        options={[
          { value: 'user', label: 'Mine' },
          { value: 'anyone', label: 'Everyone' }
        ]}
        onChange={(value) => tasksSettings.setTodayAssignee(value === 'user' ? 'user' : null)}
      />
    </div>
  </div>

  {#if rowError}
    <p class="text-warn-ink mt-1.5 text-[12.5px]" role="alert">{rowError}</p>
  {/if}

  <!-- Calm, per the leniency contract: `tasks.json` is the user's file, and one
       Valea can't parse is a thing to fix, not an app error. Project-named
       because Today merges the ledgers — "tasks.json is unreadable" alone would
       not say WHICH. Rendered whether or not there are rows.

       Keyed on the MOUNT KEY, never the sentence: two projects may share an
       `icmName`, which makes their notes identical strings, and a duplicate
       `#each` key throws in production (dev only warns). -->
  {#each ledgerNotes as entry (entry.mountKey)}
    <p class="text-ink-meta mt-1.5 text-[12.5px]">{entry.note}</p>
  {/each}

  {#if split.overdue.length > 0}
    <!-- Overdue first — the one thing that reorders a list on its own, under
         the same warn overline the Tasks list uses. -->
    <h3 class="text-overline text-warn-ink mt-2.5">Overdue · {split.overdue.length}</h3>
    {@render rowList(toRows(split.overdue))}
  {/if}

  {#if split.rest.length > 0}
    {@render rowList(toRows(split.rest))}
  {/if}

  {#if tail.length > 0}
    <p class="mt-2.5 text-[12.5px]">
      <!-- The separator's spacing is a MARGIN: Svelte trims leading and trailing
           whitespace inside an element, so `<span> · </span>` ships as a bare
           `·` and the line reads "…backlog· Plan today". -->
      {#each tail as segment, i (segment.text)}
        {#if i > 0}<span class="text-ink-meta mx-1" aria-hidden="true">·</span>{/if}
        {#if segment.emphasis}
          <a href="/tasks" class="text-act hover:underline">{segment.text}</a>
        {:else}
          <span class="text-ink-meta">{segment.text}</span>
        {/if}
      {/each}
    </p>
  {/if}
</section>

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
