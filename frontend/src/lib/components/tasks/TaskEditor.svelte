<script lang="ts">
  // The small editor a row click opens (spec §UI surfaces: title, notes, due,
  // today, priority, assignee, status). Layout-neutral — the tab hosts it in a
  // Dialog, which provides the modal chrome.
  //
  // It sends a PATCH, not a whole entry: only the fields the user actually
  // changed ride along, so `mutate_task`'s entry-level read-patch-write keeps
  // round-tripping every key Valea doesn't understand (spec §Leniency
  // contract). Clearing a field sends `null` — that is a real edit ("no due
  // date"), distinct from "don't touch it".
  //
  // Also the spec's repair affordance for an unknown status: the value stays
  // selectable and the hint explains that saving normalizes it.
  import { untrack } from 'svelte';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import type { TaskEntry } from '$lib/tasks/filters';
  import { statusOptions, taskEditPatch, unknownStatusHint } from './task-shapes';

  let {
    task,
    saving = false,
    error = null,
    onSave,
    onClose
  }: {
    task: TaskEntry;
    saving?: boolean;
    error?: string | null;
    onSave: (patch: Record<string, unknown>) => void;
    onClose: () => void;
  } = $props();

  // Seeded ONCE per opened task, deliberately: `task` is replaced wholesale by
  // every re-list (the ledger refetches on each `icm_changed` push), and
  // re-seeding on that would wipe what the user is typing mid-edit. The tab keys
  // this component on `(mountKey, taskId)`, so opening a different row remounts
  // it with fresh seeds. `untrack` states the one-shot read outright rather than
  // leaning on `$state`'s initializer semantics.
  const seed = untrack(() => ({
    title: task.title ?? '',
    notes: task.notes ?? '',
    due: task.due ?? '',
    today: task.today,
    priority: task.priority ?? '',
    assignee: task.assignee ?? 'user',
    status: task.status === '' ? 'open' : task.status
  }));

  let title = $state(seed.title);
  let notes = $state(seed.notes);
  let due = $state(seed.due);
  let today = $state(seed.today);
  let priority = $state(seed.priority);
  let assignee = $state(seed.assignee);
  let status = $state(seed.status);

  const statusHint = $derived(unknownStatusHint(task.status));
  const options = $derived(statusOptions(task.status));

  /** Only what changed; `''` on an optional text field clears it to `null`. Decided (and tested) in `task-shapes.ts`. */
  const patch = $derived(taskEditPatch(task, { title, notes, due, today, priority, assignee, status }));

  const dirty = $derived(Object.keys(patch).length > 0);
</script>

<div class="flex w-full flex-col gap-3" aria-label="Edit task">
  <p class="text-ink-heading text-[14px] font-semibold">Edit task</p>

  <div class="flex flex-col gap-1">
    <Label for="task-edit-title">Title</Label>
    <Input id="task-edit-title" type="text" bind:value={title} disabled={saving} />
  </div>

  <div class="flex flex-col gap-1">
    <Label for="task-edit-notes">Notes</Label>
    <textarea
      id="task-edit-notes"
      class="border-paper-hairline bg-paper-surface text-ink-body min-h-16 rounded-[7px] border px-2 py-1.5 text-[12.5px]"
      bind:value={notes}
      disabled={saving}
    ></textarea>
  </div>

  <div class="flex flex-wrap items-end gap-3">
    <div class="flex flex-col gap-1">
      <Label for="task-edit-due">Due</Label>
      <Input id="task-edit-due" type="date" bind:value={due} disabled={saving} />
    </div>

    <label class="text-ink-body flex items-center gap-2 pb-1.5 text-[12.5px]">
      <input type="checkbox" bind:checked={today} disabled={saving} />
      Focus today
    </label>
  </div>

  <div class="flex flex-wrap gap-3">
    <div class="flex flex-col gap-1">
      <Label for="task-edit-priority">Priority</Label>
      <select
        id="task-edit-priority"
        class="border-paper-hairline bg-paper-surface text-ink-body rounded-[7px] border px-2 py-1.5 text-[12.5px]"
        bind:value={priority}
        disabled={saving}
      >
        <option value="">None</option>
        <option value="high">High</option>
        <option value="medium">Medium</option>
        <option value="low">Low</option>
        {#if task.priority !== null && !['high', 'medium', 'low'].includes(task.priority)}
          <option value={task.priority}>{task.priority} (unknown)</option>
        {/if}
      </select>
    </div>

    <div class="flex flex-col gap-1">
      <Label for="task-edit-assignee">Assignee</Label>
      <select
        id="task-edit-assignee"
        class="border-paper-hairline bg-paper-surface text-ink-body rounded-[7px] border px-2 py-1.5 text-[12.5px]"
        bind:value={assignee}
        disabled={saving}
      >
        <option value="user">Me</option>
        <option value="agent">Agent</option>
        {#if task.assignee !== null && !['user', 'agent'].includes(task.assignee)}
          <option value={task.assignee}>{task.assignee} (unknown)</option>
        {/if}
      </select>
    </div>

    <div class="flex flex-col gap-1">
      <Label for="task-edit-status">Status</Label>
      <select
        id="task-edit-status"
        class="border-paper-hairline bg-paper-surface text-ink-body rounded-[7px] border px-2 py-1.5 text-[12.5px]"
        bind:value={status}
        disabled={saving}
      >
        {#each options as option (option.value)}
          <option value={option.value}>{option.label}</option>
        {/each}
      </select>
    </div>
  </div>

  {#if statusHint}
    <p class="text-ink-meta text-[12px]">{statusHint}</p>
  {/if}

  {#if error}
    <p class="text-warn-ink text-[12px]" role="alert">{error}</p>
  {/if}

  <div class="flex items-center justify-end gap-2">
    <Button type="button" variant="ghost" size="sm" onclick={onClose} disabled={saving}>Cancel</Button>
    <Button type="button" size="sm" disabled={saving || !dirty} onclick={() => onSave(patch)}>Save</Button>
  </div>
</div>
