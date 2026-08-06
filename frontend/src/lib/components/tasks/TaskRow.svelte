<script lang="ts">
  // One task row, on ONE line: checkbox → complete, title → editor, chips carry
  // everything else, actions appear on hover/focus. Every render decision it
  // makes lives in `task-shapes.ts` (tested there), so this file is markup plus
  // event wiring.
  //
  // Density (redesign spec §List rows). The row used to be two stacked lines —
  // title above, a wrapping meta strip below — which made a 20-task list scroll
  // twice as far as it needed to and put the same weight on "from assistant" as
  // on "3 days overdue". Now the title truncates, the meta is chips beside it,
  // and exactly one chip is allowed to be loud: the overdue pill.
  //
  // What the row stopped saying: `created_by` provenance. A "FROM ASSISTANT"
  // badge on every agent-written entry was noise on the busiest line in the
  // app; who WORKS the task (the ⚙, `showsAssigneeGear`) is the actionable
  // half, and the editor still shows the rest.
  //
  // There is deliberately NO per-row "Archive" (review round 1, M3): archival
  // is `archive_done`, which takes a MOUNT KEY and sweeps every done/dropped
  // entry in that ICM — a row-level item would have swept the whole ledger while
  // pointing at one line. The tab header's "Clear done" is the archive surface,
  // and its label already scopes itself honestly.
  //
  // The checkbox and the action cluster are SIBLINGS of the row's own title
  // button, never nested inside it — an interactive control inside another one
  // is invalid HTML and steals the row's click target (`EntryMenu.svelte`'s own
  // note makes the same point about `<a>`).
  //
  // Hit targets: the checkbox VISUAL stays the system's 15px r4 box, but the
  // button around it is 32px — §4's floor for dense lists ("the primary action
  // of the whole feature had a 15px target", critique). The action cluster is
  // hover-revealed but never hover-ONLY: it is inside the row's focus-within
  // group, so Tab reaches it, and the ⋯ menu carries Edit and Drop for anyone
  // who cannot hover a truncated title.
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import Check from '@lucide/svelte/icons/check';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import CircleSlash from '@lucide/svelte/icons/circle-slash';
  import CopyPlus from '@lucide/svelte/icons/copy-plus';
  import Pencil from '@lucide/svelte/icons/pencil';
  import type { TaskEntry } from '$lib/tasks/filters';
  import { isCompleted, overdueDays, priorityGlyph } from '$lib/tasks/filters';
  import {
    ID_LESS_TASK_NOTE,
    dueChip,
    priorityLabel,
    showsAssigneeGear,
    statusLabel,
    taskSession,
    taskSourceRender
  } from './task-shapes';
  import OverduePill from './OverduePill.svelte';
  import PriorityGlyph from './PriorityGlyph.svelte';

  let {
    task,
    mountKey,
    todayIso,
    busy = false,
    selected = false,
    sessionLive = null,
    projectTag = null,
    onToggleDone,
    onToggleToday,
    onHandOff,
    onOpen,
    onDrop,
    onRepair
  }: {
    task: TaskEntry;
    mountKey: string;
    todayIso: string;
    busy?: boolean;
    selected?: boolean;
    /** Whether the bound chat session is still alive; `null` = not known (no live dot). */
    sessionLive?: boolean | null;
    /**
     * The row's project, for lists that are NOT grouped by project (priority,
     * due, Next up) — `null` inside a project section, where the header already
     * says it. The board card carries the same tag at the same size.
     */
    projectTag?: string | null;
    onToggleDone: () => void;
    /** Flip the `today` flag — the day's triage, one click from the row. */
    onToggleToday: () => void;
    /**
     * Start a session seeded with this task. Optional: a list that has no
     * assistant to hand to (or no session route) renders no button at all
     * rather than a dead one.
     */
    onHandOff?: () => void;
    onOpen: () => void;
    onDrop: () => void;
    /** Copy an id-less entry into a properly stamped task (see `ID_LESS_TASK_NOTE`). */
    onRepair: () => void;
  } = $props();

  const done = $derived(isCompleted(task));
  const due = $derived(dueChip(task, todayIso));
  const overdue = $derived(overdueDays(task, todayIso));
  // An unknown priority has no glyph (a glyph would launder it) — it keeps the
  // verbatim text chip the leniency contract promises.
  const priorityText = $derived(priorityGlyph(task.priority) === null ? priorityLabel(task.priority) : null);
  const source = $derived(task.source === null ? null : taskSourceRender(task.source, mountKey));
  // The chip shows a basename (link kinds) or a source that may be truncated by
  // `max-w-[24ch]`; the FULL locator is otherwise exposed nowhere on the row.
  const sourceTitle = $derived(task.source?.trim() ?? undefined);
  const session = $derived(taskSession(task));
  // `open` is the resting state and needs no chip; everything else — including
  // an unknown status, rendered verbatim — earns one.
  const statusChip = $derived(task.status === 'open' ? null : statusLabel(task.status));
  const addressable = $derived(task.id !== null);
  /** The hover/focus reveal, shared by every control in the action cluster. */
  const revealed =
    'opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 focus-visible:opacity-100';
</script>

<li class="group/row border-paper-hairline flex items-start gap-1 border-b py-0.5 last:border-b-0">
  <button
    type="button"
    role="checkbox"
    aria-checked={done}
    aria-label={done ? `Reopen ${task.title ?? 'task'}` : `Complete ${task.title ?? 'task'}`}
    disabled={busy || !addressable}
    onclick={onToggleDone}
    class="group/check flex size-8 shrink-0 items-center justify-center"
  >
    <span
      class={[
        'border-paper-button-border flex size-[15px] items-center justify-center rounded-[4px] border transition-colors',
        done ? 'bg-act text-primary-foreground border-transparent' : 'bg-paper-card group-hover/check:border-ink-meta',
        busy || !addressable ? 'cursor-not-allowed opacity-50' : ''
      ]}
    >
      {#if done}
        <Check class="size-3" strokeWidth={2.5} />
      {/if}
    </span>
  </button>

  <!-- Done rows read as receipts (§8): dimmed, struck through, the green check
       standing in for the timestamp line an audit row would carry. -->
  <div class={['min-w-0 flex-1', done ? 'opacity-75' : '']}>
    <!-- The single line. The title is the only shrinkable item, so it truncates
         first and every chip keeps its full width; `overflow-hidden` clips the
         tail when even the chips run out of room. -->
    <div class="flex h-8 min-w-0 items-center gap-1.5 overflow-hidden">
      <PriorityGlyph priority={task.priority} />

      <button
        type="button"
        disabled={!addressable}
        onclick={onOpen}
        title={task.title ?? undefined}
        class={[
          'min-w-0 truncate text-left',
          addressable ? 'hover:underline' : 'cursor-default',
          selected ? 'underline' : ''
        ]}
      >
        <span class={['text-[13.5px]', done ? 'text-ink-meta line-through' : 'text-ink-body']}>
          {task.title ?? '(untitled)'}
        </span>
      </button>

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
      {#if statusChip}
        <span class="text-ink-meta shrink-0 text-[11.5px]">{statusChip}</span>
      {/if}
      {#if priorityText}
        <span class="text-ink-meta shrink-0 text-[11.5px]">{priorityText}</span>
      {/if}
      {#if task.today}
        <span class="text-act shrink-0 text-[11.5px]">focus</span>
      {/if}
      {#if overdue !== null}
        <!-- The one loud chip in the list: overdue is the only state that earns
             a filled pill. Everything else stays quiet text. -->
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
      {#if source}
        <!-- §5 source chip: dot color names the source type (terracotta =
             email, amber = document). Unrecognized locators stay plain TEXT,
             verbatim — a confidently wrong link is worse, and so is a
             basename sliced out of prose. A link kind's label is the locator's
             basename; its href still addresses the whole locator, and `title`
             carries the full string on both variants. -->
        {#if source.kind === 'text'}
          <span class="text-ink-meta max-w-[24ch] shrink-0 truncate text-[11.5px]" title={sourceTitle}>
            {source.label}
          </span>
        {:else}
          <a
            href={source.href}
            title={sourceTitle}
            class="border-paper-chip-border text-ink-secondary hover:text-ink-heading inline-flex max-w-[24ch] shrink-0 items-center gap-1.5 rounded-full border px-2 py-0.5 text-[10.5px] hover:underline"
          >
            <span
              class={['size-1.5 shrink-0 rounded-full', source.kind === 'mail' ? 'bg-warn-dot' : 'bg-suggest-dash']}
              aria-hidden="true"
            ></span>
            <span class="truncate">{source.label}</span>
          </a>
        {/if}
      {/if}
      {#if session !== null}
        <!-- The row's half of "hand to assistant": the work is happening in a
             chat, and this is the way back to it. The dot only appears when the
             session is KNOWN to be live — `null` means nobody asked.
             The id is ENCODED: it comes off a hand-editable file, same as
             `runTranscriptHref`'s and the audit log's. -->
        <a
          href={`/chat?session=${encodeURIComponent(session)}`}
          class="border-paper-chip-border text-ink-secondary hover:text-ink-heading inline-flex shrink-0 items-center gap-1 rounded-full border px-2 py-0.5 text-[10.5px] hover:underline"
        >
          {#if sessionLive}<span class="bg-act-dot size-1.5 rounded-full" aria-hidden="true"></span>{/if}
          session
        </a>
      {/if}
      {#if projectTag}
        <!-- Last and quietest: which project a row belongs to only matters when
             the list isn't already grouped by project, and it never competes
             with the due state for attention. -->
        <span class="text-ink-meta shrink-0 text-[9px]">{projectTag}</span>
      {/if}
    </div>

    {#if !addressable}
      <p class="text-ink-meta pb-1 text-[11.5px]">{ID_LESS_TASK_NOTE}</p>
      <button
        type="button"
        disabled={busy}
        onclick={onRepair}
        class="text-ink-secondary hover:text-ink-heading mb-1 inline-flex items-center gap-1 text-[11.5px] hover:underline"
      >
        <CopyPlus class="size-3" strokeWidth={1.5} />
        Copy into a proper task
      </button>
    {/if}
  </div>

  {#if addressable}
    <div class="flex h-8 shrink-0 items-center gap-0.5">
      {#if onHandOff}
        <!-- The cockpit differentiator, and the first thing in the cluster: the
             row hands its own task to a session seeded with it. The label is an
             arrow because the button MOVES the task somewhere; the aria-label
             says the sentence the arrow is short for. -->
        <button
          type="button"
          disabled={busy}
          onclick={onHandOff}
          aria-label="Hand to the assistant"
          class={[
            'text-ink-meta hover:bg-paper-card hover:text-ink-heading flex h-8 items-center rounded-md px-1.5 text-[11.5px] whitespace-nowrap',
            revealed
          ]}
        >
          → Assistant
        </button>
      {/if}

      <button
        type="button"
        disabled={busy}
        onclick={onToggleToday}
        aria-label={task.today ? 'Remove from today' : 'Flag for today'}
        class={[
          'text-ink-meta hover:bg-paper-card hover:text-ink-heading flex h-8 items-center rounded-md px-1.5 text-[11.5px] whitespace-nowrap',
          revealed
        ]}
      >
        {task.today ? 'Today ✓' : 'Today'}
      </button>

      <DropdownMenu.Root>
        <DropdownMenu.Trigger>
          {#snippet child({ props })}
            <button
              type="button"
              {...props}
              aria-label={`Actions for ${task.title ?? 'task'}`}
              class={[
                'text-ink-meta hover:bg-paper-card hover:text-ink-heading data-[state=open]:bg-paper-card flex size-8 shrink-0 items-center justify-center rounded-md data-[state=open]:opacity-100',
                revealed
              ]}
            >
              <Ellipsis class="size-4" strokeWidth={1.5} />
            </button>
          {/snippet}
        </DropdownMenu.Trigger>
        <DropdownMenu.Content align="end">
          <!-- Edit lives here as well as on the title: the title is now a
               truncated single line, and a menu item is the keyboard and touch
               way to the editor. -->
          <DropdownMenu.Item onSelect={onOpen}>
            <Pencil class="size-3.5" strokeWidth={1.5} />
            Edit
          </DropdownMenu.Item>
          <DropdownMenu.Item onSelect={onDrop}>
            <CircleSlash class="size-3.5" strokeWidth={1.5} />
            Drop
          </DropdownMenu.Item>
        </DropdownMenu.Content>
      </DropdownMenu.Root>
    </div>
  {/if}
</li>
