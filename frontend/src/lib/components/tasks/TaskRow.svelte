<script lang="ts">
  // One task row: checkbox → complete, row click → editor, overflow → drop.
  // Every render decision it makes lives in `task-shapes.ts` (tested there), so
  // this file is markup plus event wiring.
  //
  // There is deliberately NO per-row "Archive" (review round 1, M3): archival
  // is `archive_done`, which takes a MOUNT KEY and sweeps every done/dropped
  // entry in that ICM — a row-level item would have swept the whole ledger while
  // pointing at one line. The tab header's "Clear done" is the archive surface,
  // and its label already scopes itself honestly.
  //
  // The checkbox and the overflow menu are SIBLINGS of the row's own button,
  // never nested inside it — an interactive control inside another one is
  // invalid HTML and steals the row's click target (`EntryMenu.svelte`'s own
  // note makes the same point about `<a>`).
  import * as DropdownMenu from '$lib/components/ui/dropdown-menu/index.js';
  import Check from '@lucide/svelte/icons/check';
  import Ellipsis from '@lucide/svelte/icons/ellipsis';
  import CircleSlash from '@lucide/svelte/icons/circle-slash';
  import CopyPlus from '@lucide/svelte/icons/copy-plus';
  import type { TaskEntry } from '$lib/tasks/filters';
  import { isCompleted } from '$lib/tasks/filters';
  import {
    ID_LESS_TASK_NOTE,
    assigneeLabel,
    dueChip,
    priorityLabel,
    showsAgentBadge,
    statusLabel,
    taskSourceRender
  } from './task-shapes';

  let {
    task,
    mountKey,
    todayIso,
    busy = false,
    selected = false,
    onToggleDone,
    onOpen,
    onDrop,
    onRepair
  }: {
    task: TaskEntry;
    mountKey: string;
    todayIso: string;
    busy?: boolean;
    selected?: boolean;
    onToggleDone: () => void;
    onOpen: () => void;
    onDrop: () => void;
    /** Copy an id-less entry into a properly stamped task (see `ID_LESS_TASK_NOTE`). */
    onRepair: () => void;
  } = $props();

  const done = $derived(isCompleted(task));
  const due = $derived(dueChip(task, todayIso));
  const priority = $derived(priorityLabel(task.priority));
  const source = $derived(task.source === null ? null : taskSourceRender(task.source, mountKey));
  // `open` is the resting state and needs no chip; everything else — including
  // an unknown status, rendered verbatim — earns one.
  const statusChip = $derived(task.status === 'open' ? null : statusLabel(task.status));
  const addressable = $derived(task.id !== null);
</script>

<li class="group/row border-paper-hairline flex items-start gap-2.5 border-b py-2.5 last:border-b-0">
  <button
    type="button"
    role="checkbox"
    aria-checked={done}
    aria-label={done ? `Reopen ${task.title ?? 'task'}` : `Complete ${task.title ?? 'task'}`}
    disabled={busy || !addressable}
    onclick={onToggleDone}
    class={[
      'border-paper-button-border mt-0.5 flex size-[15px] shrink-0 items-center justify-center rounded-[4px] border transition-colors',
      done ? 'bg-act text-paper-card border-transparent' : 'bg-paper-card hover:border-ink-meta',
      busy || !addressable ? 'cursor-not-allowed opacity-50' : ''
    ]}
  >
    {#if done}
      <Check class="size-3" strokeWidth={2.5} />
    {/if}
  </button>

  <div class="min-w-0 flex-1">
    <button
      type="button"
      disabled={!addressable}
      onclick={onOpen}
      class={[
        'w-full text-left',
        addressable ? 'hover:underline' : 'cursor-default',
        selected ? 'underline' : ''
      ]}
    >
      <span class={['text-[13.5px]', done ? 'text-ink-meta line-through' : 'text-ink-body']}>
        {task.title ?? '(untitled)'}
      </span>
    </button>

    <div class="mt-0.5 flex flex-wrap items-center gap-x-2 gap-y-1">
      {#if task.today}
        <span class="text-act text-[11.5px]">focus</span>
      {/if}
      {#if due}
        <span
          class={[
            'text-[11.5px] tabular-nums',
            due.tone === 'overdue' ? 'text-warn-ink' : '',
            due.tone === 'today' ? 'text-act' : '',
            due.tone === 'later' ? 'text-ink-meta' : '',
            due.tone === 'unparsed' ? 'text-ink-meta italic' : ''
          ]}
        >
          {due.tone === 'unparsed' ? `due ${due.text} (not a date)` : `due ${due.text}`}
        </span>
      {/if}
      {#if statusChip}
        <span class="text-ink-meta text-[11.5px]">{statusChip}</span>
      {/if}
      {#if priority}
        <span class="text-ink-meta text-[11.5px]">{priority}</span>
      {/if}
      {#if task.assignee === 'agent'}
        <span class="text-ink-meta text-[11.5px]">{assigneeLabel(task.assignee)}</span>
      {/if}
      {#if showsAgentBadge(task)}
        <span class="bg-paper-pill text-ink-secondary rounded-full px-1.5 py-0.5 text-[10.5px]">from agent</span>
      {/if}
      {#if source}
        {#if source.kind === 'text'}
          <span class="text-ink-meta truncate text-[11.5px]">{source.label}</span>
        {:else}
          <a href={source.href} class="text-ink-meta truncate text-[11.5px] hover:underline">{source.label}</a>
        {/if}
      {/if}
    </div>

    {#if !addressable}
      <p class="text-ink-meta mt-1 text-[11.5px]">{ID_LESS_TASK_NOTE}</p>
      <button
        type="button"
        disabled={busy}
        onclick={onRepair}
        class="text-ink-secondary hover:text-ink-heading mt-1 inline-flex items-center gap-1 text-[11.5px] hover:underline"
      >
        <CopyPlus class="size-3" strokeWidth={1.5} />
        Copy into a proper task
      </button>
    {/if}
  </div>

  {#if addressable}
    <DropdownMenu.Root>
      <DropdownMenu.Trigger>
        {#snippet child({ props })}
          <button
            type="button"
            {...props}
            aria-label={`Actions for ${task.title ?? 'task'}`}
            class="text-ink-meta hover:bg-paper-card hover:text-ink-heading data-[state=open]:bg-paper-card flex size-7 shrink-0 items-center justify-center rounded-md opacity-0 transition-opacity group-hover/row:opacity-100 group-focus-within/row:opacity-100 focus-visible:opacity-100 data-[state=open]:opacity-100"
          >
            <Ellipsis class="size-4" strokeWidth={1.5} />
          </button>
        {/snippet}
      </DropdownMenu.Trigger>
      <DropdownMenu.Content align="end">
        <DropdownMenu.Item onSelect={onDrop}>
          <CircleSlash class="size-3.5" strokeWidth={1.5} />
          Drop
        </DropdownMenu.Item>
      </DropdownMenu.Content>
    </DropdownMenu.Root>
  {/if}
</li>
