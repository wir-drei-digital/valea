<script lang="ts">
  // One board card: a two-line title with the row's chips under it (redesign
  // spec §Board view). The card IS the click target — it opens the editor —
  // and the drag handle, so there is nothing else on it to hit.
  //
  // What it borrows from `TaskRow` and what it drops. The chips are the row's,
  // verbatim (priority glyph, ⚙, focus, overdue pill / due text, session,
  // project tag), minus every hover action: a board card has no checkbox, no
  // Today toggle and no ⋯ menu, because a control inside the card would steal
  // the drag gesture and nest an interactive element inside a button.
  //
  // The session chip is TEXT here, not the row's link, for the same reason: an
  // <a> inside a <button> is invalid HTML and swallows the card's own click
  // (`TaskRow`'s own note makes this point about the checkbox). The way to the
  // session from the board is the card → editor → the row in the list.
  //
  // No STATUS chip either: on the board the column is the status, including a
  // custom one, whose column label is the verbatim string the chip would show.
  //
  // No SOURCE chip, deliberately (spec §Board view lists the card's chips and
  // source is not among them): both LINK kinds would be nested anchors, and
  // carrying only the freeform text kind would make provenance appear and
  // disappear by kind, which is worse than a card that consistently doesn't
  // claim to show it. The list row is where a task's source lives.
  //
  // Spans rather than <p>/<div> for the card's own text blocks: a <button>'s
  // content model is phrasing content, and these carry `block`/`flex` anyway.
  import type { TaskEntry } from '$lib/tasks/filters';
  import { isCompleted, overdueDays, priorityGlyph } from '$lib/tasks/filters';
  import { ID_LESS_TASK_NOTE, dueChip, priorityLabel, showsAssigneeGear, taskSession } from './task-shapes';
  import OverduePill from './OverduePill.svelte';
  import PriorityGlyph from './PriorityGlyph.svelte';

  let {
    task,
    icmName,
    todayIso,
    sessionLive = null,
    draggable = false,
    dragging = false,
    onOpen,
    onDragStart,
    onDragEnd
  }: {
    /** The entry AS THE BOARD DERIVED IT (`boardTask`) — a pending drop has already moved its status. */
    task: TaskEntry;
    /** The card's project. The board is never grouped by project, so every card carries the tag. */
    icmName: string;
    todayIso: string;
    /** Whether the bound chat session is still alive; `null` = not known (no live dot). */
    sessionLive?: boolean | null;
    /** Id-less entries are inert (see `ID_LESS_TASK_NOTE`): nothing to address, nothing to patch. */
    draggable?: boolean;
    /** This card is the one currently being dragged — dimmed, so the drag reads as a move. */
    dragging?: boolean;
    onOpen: () => void;
    onDragStart: (event: DragEvent) => void;
    onDragEnd: () => void;
  } = $props();

  const addressable = $derived(task.id !== null);
  const movable = $derived(addressable && draggable);
  // Done cards read as receipts, exactly like done rows (§8).
  const done = $derived(isCompleted(task));
  const due = $derived(dueChip(task, todayIso));
  const overdue = $derived(overdueDays(task, todayIso));
  // An unknown priority has no glyph (a glyph would launder it) — it keeps the
  // verbatim text chip the leniency contract promises.
  const priorityText = $derived(priorityGlyph(task.priority) === null ? priorityLabel(task.priority) : null);
  const session = $derived(taskSession(task));
</script>

<button
  type="button"
  draggable={movable}
  disabled={!addressable}
  title={task.title ?? undefined}
  ondragstart={onDragStart}
  ondragend={onDragEnd}
  onclick={onOpen}
  class={[
    'border-paper-border bg-paper-card shadow-card block w-full rounded-[10px] border p-2.5 text-left transition-colors',
    movable ? 'cursor-grab active:cursor-grabbing' : 'cursor-default',
    addressable ? 'hover:border-paper-button-border' : '',
    dragging ? 'opacity-40' : done ? 'opacity-75' : ''
  ]}
>
  <span class={['line-clamp-2 text-[13px]', done ? 'text-ink-meta line-through' : 'text-ink-body']}>
    {task.title ?? '(untitled)'}
  </span>

  <span class="mt-1 flex flex-wrap items-center gap-1.5">
    <PriorityGlyph priority={task.priority} />

    {#if showsAssigneeGear(task)}
      <!-- `role="img"` is what makes the aria-label reach a screen reader at
           all: a bare <span> is generic, and ARIA forbids naming it. -->
      <span
        class="text-ink-meta shrink-0 text-[11px]"
        role="img"
        title="assigned to the assistant"
        aria-label="assigned to the assistant"
      >⚙</span>
    {/if}
    {#if priorityText}
      <span class="text-ink-meta shrink-0 text-[11.5px]">{priorityText}</span>
    {/if}
    {#if task.today}
      <!-- Why this card is at the top of its column — the flag is the first
           sort key, and without it the order looks arbitrary. -->
      <span class="text-act shrink-0 text-[11.5px]">focus</span>
    {/if}
    {#if overdue !== null}
      <!-- The one loud chip on the board too: overdue is the only state that
           earns a filled pill. -->
      <OverduePill days={overdue} />
    {:else if due}
      <span
        class={[
          'shrink-0 text-[11.5px] tabular-nums',
          due.tone === 'today' ? 'text-act' : '',
          due.tone === 'later' ? 'text-ink-meta' : '',
          due.tone === 'unparsed' ? 'text-ink-meta italic' : ''
        ]}
      >
        {due.text}
      </span>
    {/if}
    {#if session !== null}
      <span
        class="border-paper-chip-border text-ink-secondary inline-flex shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-[10.5px]"
      >
        {#if sessionLive}<span class="bg-act-dot size-1.5 rounded-full" aria-hidden="true"></span>{/if}
        session
      </span>
    {/if}

    <!-- Last and quietest, as in the list: which project this is, at the size
         that never competes with the due state. `shrink-0` for the same reason
         the row's tag has it — a long project name must not be squeezed to
         nothing by the chips beside it. -->
    <span class="text-ink-meta shrink-0 text-[9px]">{icmName}</span>
  </span>

  {#if !addressable}
    <!-- No repair button here (that lives on the list row): a second control
         inside the card would be invalid inside a <button> and unreachable by
         drag anyway. The note says why the card cannot move. -->
    <span class="text-ink-meta mt-1 block text-[11.5px]">{ID_LESS_TASK_NOTE}</span>
  {/if}
</button>
