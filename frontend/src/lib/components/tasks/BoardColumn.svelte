<script lang="ts">
  // One board column: a labelled track that is also a drop target (redesign
  // spec §Board view). It owns no task state — `TaskBoard` derives the column
  // and renders the cards into it; this file is the container, the header and
  // the DnD plumbing.
  //
  // A CUSTOM column (a status Valea doesn't know, found in the file) is drawn
  // dashed: same affordances, visibly "yours, not ours". Its label is the raw
  // status string, verbatim — `boardLabel` decided that, not this markup.
  //
  // Empty columns are drop targets too (that is how a status gets its first
  // card), so the body keeps a minimum height rather than collapsing to
  // nothing.
  import type { Snippet } from 'svelte';
  import type { BoardColumn } from '$lib/tasks/board';

  let {
    column,
    onDrop,
    children
  }: {
    column: BoardColumn;
    /** Called with THIS column's status when a card is dropped anywhere inside it. */
    onDrop: (status: string) => void;
    /** The column's cards, plus the Done column's archive footer. */
    children: Snippet;
  } = $props();

  /** Whether a drag is currently over this column — the only "you can drop here" the browser won't draw. */
  let over = $state(false);

  function handleDragOver(event: DragEvent): void {
    // Preventing the default on dragover is literally what MAKES an element a
    // drop target; without it the drop event never fires.
    event.preventDefault();
    if (event.dataTransfer !== null) event.dataTransfer.dropEffect = 'move';
    over = true;
  }

  function handleDragLeave(event: DragEvent): void {
    // dragleave also fires on every hop between the column's own children, so
    // only a leave that actually lands OUTSIDE the column clears the highlight
    // — otherwise it strobes as the pointer crosses each card.
    const next = event.relatedTarget;
    const self = event.currentTarget;
    if (next instanceof Node && self instanceof Node && self.contains(next)) return;
    over = false;
  }

  function handleDrop(event: DragEvent): void {
    event.preventDefault();
    over = false;
    onDrop(column.status);
  }
</script>

<!-- `role="group"` names the column for assistive tech, which is also what
     lets it carry drop handlers at all (svelte a11y: a static element with
     dragover/drop needs a role). Drag itself is never the only way to move a
     card — the editor's status select is the keyboard and touch path. -->
<div
  role="group"
  aria-label={`${column.label} column`}
  ondragover={handleDragOver}
  ondragleave={handleDragLeave}
  ondrop={handleDrop}
  class={[
    'flex min-w-[220px] flex-1 flex-col rounded-[10px] border p-2.5 transition-colors',
    // One or the other, never both: two border-color utilities on the same
    // element resolve by stylesheet order, not by the order written here.
    over ? 'border-act bg-act-tint' : 'border-paper-border bg-paper-track',
    column.custom ? 'border-dashed' : ''
  ]}
>
  <div class="flex items-baseline justify-between gap-2">
    <h3 class="text-overline truncate">{column.label}</h3>
    <span class="text-ink-meta shrink-0 text-[11.5px] tabular-nums">{column.tasks.length}</span>
  </div>

  <div class="mt-2 flex min-h-[56px] flex-col gap-2">
    {@render children()}
  </div>
</div>
