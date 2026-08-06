<script lang="ts">
  // The status board (redesign spec §Board view): the filtered rows, dealt into
  // Open · In progress · Done plus one column per custom status found in the
  // files, with native HTML5 drag between them.
  //
  // The rows it is given are exactly the list's — same view, assignee, search
  // and no grouping (the board IS grouped, by status). What it adds is the
  // column model (`lib/tasks/board.ts`, tested there) and two writes:
  // a drop patches one entry's `status`, and the Done column's footer archives
  // every finished entry per project.
  //
  // DRAG IS OPTIMISTIC (pre-flight ruling 2026-08-06). A drop puts the card in
  // its new column IMMEDIATELY, through a per-drop overlay keyed
  // `mountKey/taskId`, and the overlay is deleted the moment the write settles
  // — on success the re-listed store rows already carry the new status, on
  // failure the card visibly snaps back with the error line saying why. So the
  // board can never disagree with the file for longer than one in-flight write,
  // and a dropped card never sits still pretending nothing happened.
  //
  // Keyboard and touch never drag: the fallback is the editor's status select,
  // one card click away, which is why every card is a button.
  import { Button } from '$lib/components/ui/button/index.js';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { boardTask, deriveColumns, dropPatch } from '$lib/tasks/board';
  import { isCompleted, type TaskEntry } from '$lib/tasks/filters';
  import { sessionLiveById } from '$lib/tasks/handoff';
  import { tasksStore, type TaskIcm } from '$lib/tasks/store.svelte';
  import { rowKeys, taskErrorMessage, taskSession } from './task-shapes';
  import BoardColumn from './BoardColumn.svelte';
  import TaskCard from './TaskCard.svelte';

  /** One card's row: the entry and the ledger it came from — the tab's `Row`, minus its key. */
  type BoardRow = { icm: TaskIcm; task: TaskEntry };

  let {
    rows,
    todayIso,
    onOpen,
    onError
  }: {
    rows: BoardRow[];
    todayIso: string;
    onOpen: (mountKey: string, task: TaskEntry) => void;
    /**
     * The tab's one error line. `null` CLEARS it: a new drop or sweep starts
     * clean, so a failure from three drags ago can't sit above a board where
     * everything since has worked.
     */
    onError: (message: string | null) => void;
  } = $props();

  /** The card being dragged, addressed the way every write is. `null` between drags. */
  let dragging = $state<{ mountKey: string; taskId: string } | null>(null);
  /** The optimistic overlay: `mountKey/taskId` → the column it was just dropped on. Per-drop, self-clearing. */
  let pending = $state<Map<string, string>>(new Map());
  let confirmingArchive = $state(false);
  let archiving = $state(false);

  function address(mountKey: string, taskId: string | null): string {
    return `${mountKey}/${taskId}`;
  }

  /**
   * Every row as a card: the entry the columns derive from (file status, or the
   * pending drop's), its project, and a key no twin can collide with.
   *
   * `boardTask` returns the SAME entry when nothing was overridden, so the map
   * back from a derived entry to its project is object identity — `deriveColumns`
   * filters and sorts, it never copies.
   */
  const cards = $derived.by(() => {
    const keys = rowKeys(rows.map(({ icm, task }) => ({ mountKey: icm.mountKey, id: task.id })));
    return rows.map((row, index) => ({
      key: keys[index],
      row,
      task: boardTask(row.task, pending.get(address(row.icm.mountKey, row.task.id)))
    }));
  });

  const columns = $derived.by(() => {
    const byTask = new Map(cards.map((card) => [card.task, card]));
    // `tasks` rides along deliberately: `BoardColumn` types its prop as the
    // whole `BoardColumn` and renders `tasks.length` as the column's count.
    return deriveColumns(cards.map((card) => card.task)).map((column) => ({
      ...column,
      cards: column.tasks.flatMap((task) => {
        const card = byTask.get(task);
        return card === undefined ? [] : [card];
      })
    }));
  });

  /**
   * Every project on the board with finished entries IN ITS FILE, and how many.
   *
   * The count is the ledger's, not the Done column's, because that is what the
   * sweep takes: `archive_done` moves every done/dropped entry in the file,
   * including the ones the current filters hide (the Today view hides all of
   * them). A confirmation that promised a smaller number would be lying about
   * the write it is asking for — the same ruling the list's Clear done follows.
   */
  const archivable = $derived.by(() => {
    const seen = new Map<string, TaskIcm>();
    for (const { icm } of rows) seen.set(icm.mountKey, icm);
    return [...seen.values()]
      .map((icm) => ({
        mountKey: icm.mountKey,
        name: icm.icmName || icm.mountKey,
        count: icm.tasks.filter(isCompleted).length
      }))
      .filter((entry) => entry.count > 0);
  });

  const archivableTotal = $derived(archivable.reduce((total, entry) => total + entry.count, 0));

  // An ARMED confirmation must not survive its own sweep set emptying — a
  // search that hides every project takes the card off screen without
  // cancelling it, and it would come back later attached to a sweep nobody
  // remembers asking for (the same rule `changeFilters` enforces for the
  // list's Clear done). Writes a value it does not read, so it cannot re-arm
  // itself.
  $effect(() => {
    if (archivableTotal === 0) confirmingArchive = false;
  });

  function handleDragStart(event: DragEvent, row: BoardRow): void {
    if (row.task.id === null) return;
    dragging = { mountKey: row.icm.mountKey, taskId: row.task.id };
    if (event.dataTransfer !== null) {
      // Firefox starts no drag AT ALL without a payload on the transfer. The
      // text is the title rather than an internal key, because it is also what
      // a drop outside the app would paste.
      event.dataTransfer.setData('text/plain', row.task.title ?? '(untitled)');
      event.dataTransfer.effectAllowed = 'move';
    }
  }

  async function handleDrop(columnStatus: string): Promise<void> {
    const drag = dragging;
    dragging = null;
    if (drag === null) return; // a drag that started somewhere else entirely
    const row = rows.find(({ icm, task }) => icm.mountKey === drag.mountKey && task.id === drag.taskId);
    if (row === undefined) return;

    const key = address(drag.mountKey, drag.taskId);
    // Against what the card SHOWS, not what the file says: while an earlier
    // drop is still in flight the two differ, and dropping a card back where it
    // visibly came from has to write that back.
    const patch = dropPatch(boardTask(row.task, pending.get(key)), columnStatus);
    if (patch === null) return; // same column, or an id-less card

    onError(null);
    pending = new Map(pending).set(key, columnStatus); // the card moves NOW
    const outcome = await tasksStore.patchTask(drag.mountKey, drag.taskId, patch);
    // Both outcomes drop the overlay: on success the re-listed rows carry the
    // new status, on failure `refreshTasks` has restored the file's and the
    // card snaps back under the error line.
    const next = new Map(pending);
    next.delete(key);
    pending = next;
    if (!outcome.ok) onError(taskErrorMessage(outcome.error));
  }

  /**
   * Archive every project's finished tasks, one file at a time. Sequential on
   * purpose: each sweep is a read-write of one ledger, and the first failure
   * stops the run naming the project it stopped at — everything before it is
   * already archived, and saying so is the only way the user knows where they
   * stand.
   */
  async function archiveAll(): Promise<void> {
    // Snapshot: `archivable` recomputes (and shrinks) as each sweep lands.
    const projects = archivable;
    archiving = true;
    onError(null);
    try {
      for (const project of projects) {
        const outcome = await tasksStore.clearDone(project.mountKey);
        if (!outcome.ok) {
          onError(`${project.name}: ${taskErrorMessage(outcome.error)}`);
          return;
        }
      }
      confirmingArchive = false;
    } finally {
      archiving = false;
    }
  }
</script>

<div class="flex items-start gap-3 overflow-x-auto pt-2">
  {#each columns as column (column.status)}
    <BoardColumn {column} dragActive={dragging !== null} onDrop={(status) => void handleDrop(status)}>
      {#each column.cards as card (card.key)}
        <!-- The bound session's live dot, when the recency window still knows
             it: `sessionLiveById` answers `null` for an id that has aged out,
             and the chip then renders without a dot rather than claiming
             "ended". -->
        {@const session = taskSession(card.task)}
        <TaskCard
          task={card.task}
          icmName={card.row.icm.icmName || card.row.icm.mountKey}
          {todayIso}
          sessionLive={session === null ? null : sessionLiveById(recentSessionsStore.groups, session)}
          draggable
          dragging={dragging !== null &&
            dragging.mountKey === card.row.icm.mountKey &&
            dragging.taskId === card.task.id}
          onOpen={() => onOpen(card.row.icm.mountKey, card.row.task)}
          onDragStart={(event) => handleDragStart(event, card.row)}
          onDragEnd={() => (dragging = null)}
        />
      {/each}

      {#if column.status === 'done' && archivableTotal > 0}
        {#if confirmingArchive}
          <!-- The card counts the LEDGERS, not the column: archiving sweeps
               every finished entry in each file, including ones these filters
               hide (in the Today view, that is all of them). -->
          <div class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2 rounded-[10px] border p-2.5">
            <p class="text-ink-body text-[12.5px]">
              Archive {archivableTotal === 1 ? 'the finished task' : `${archivableTotal} finished tasks`}? They move to
              each project's archive file.
            </p>
            <ul class="text-ink-meta flex flex-col text-[11.5px]">
              {#each archivable as project (project.mountKey)}
                <li class="tabular-nums">{project.name}: {project.count}</li>
              {/each}
            </ul>
            {#if column.cards.length < archivableTotal}
              <!-- Said only when the sweep is bigger than the column: the
                   numbers would otherwise look like a miscount. -->
              <p class="text-ink-meta text-[11.5px]">This includes finished tasks the current filters hide.</p>
            {/if}
            <div class="flex flex-wrap items-center gap-2">
              <Button
                type="button"
                variant="ghost"
                size="sm"
                onclick={() => (confirmingArchive = false)}
                disabled={archiving}
              >
                Cancel
              </Button>
              <Button type="button" variant="outline" size="sm" onclick={() => void archiveAll()} disabled={archiving}>
                Archive
              </Button>
            </div>
          </div>
        {:else}
          <button
            type="button"
            disabled={archiving}
            onclick={() => (confirmingArchive = true)}
            class="text-ink-meta hover:text-ink-heading self-start text-[11.5px] hover:underline"
          >
            Archive all
          </button>
        {/if}
      {/if}
    </BoardColumn>
  {/each}
</div>
