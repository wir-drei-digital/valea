<script lang="ts">
  // The small editor a row click opens (spec §UI surfaces: title, notes, due,
  // today, priority, assignee, status). Layout-neutral — the tab hosts it in a
  // Dialog, which provides the modal chrome and the accessible title.
  //
  // Every control wears the app's clothes: `NativeSelect` for the three
  // dropdowns and a hand-drawn checkbox matching the task rows' 15px r4 box —
  // the earlier build mixed OS-chrome selects and a platform-blue checkbox into
  // a paper dialog, thirty pixels from the app's own checkbox design
  // (critique: "it looks like a different app than the list behind it").
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
  import Check from '@lucide/svelte/icons/check';
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { NativeSelect } from '$lib/components/ui/native-select/index.js';
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

<div class="flex w-full flex-col gap-3">
  <div class="flex flex-col gap-1">
    <Label for="task-edit-title">Title</Label>
    <Input id="task-edit-title" type="text" bind:value={title} disabled={saving} />
  </div>

  <div class="flex flex-col gap-1">
    <Label for="task-edit-notes">Notes</Label>
    <textarea
      id="task-edit-notes"
      class="border-input focus-visible:border-ring focus-visible:ring-ring/50 text-ink-body min-h-16 rounded-lg border bg-transparent px-2.5 py-1.5 text-sm transition-colors outline-none focus-visible:ring-3 disabled:pointer-events-none disabled:cursor-not-allowed disabled:opacity-50"
      bind:value={notes}
      disabled={saving}
    ></textarea>
  </div>

  <div class="flex flex-wrap items-end gap-3">
    <div class="flex flex-col gap-1">
      <Label for="task-edit-due">Due</Label>
      <Input id="task-edit-due" type="date" bind:value={due} disabled={saving} class="w-auto" />
    </div>

    <!-- The rows' own checkbox design, not the platform's: sr-only input +
         drawn 15px r4 box, inside a comfortably tall label. -->
    <label class="text-ink-body flex h-8 cursor-pointer items-center gap-2 text-[12.5px] select-none">
      <input type="checkbox" class="peer sr-only" bind:checked={today} disabled={saving} />
      <span
        class={[
          'border-paper-button-border peer-focus-visible:ring-ring/50 flex size-[15px] items-center justify-center rounded-[4px] border transition-colors peer-focus-visible:ring-3',
          today ? 'bg-act text-paper-card border-transparent' : 'bg-paper-card'
        ]}
      >
        {#if today}
          <Check class="size-3" strokeWidth={2.5} />
        {/if}
      </span>
      Focus today
    </label>
  </div>

  <div class="flex flex-wrap gap-3">
    <div class="flex flex-col gap-1">
      <Label for="task-edit-priority">Priority</Label>
      <NativeSelect id="task-edit-priority" bind:value={priority} disabled={saving}>
        <option value="">None</option>
        <option value="high">High</option>
        <option value="medium">Medium</option>
        <option value="low">Low</option>
        {#if task.priority !== null && !['high', 'medium', 'low'].includes(task.priority)}
          <option value={task.priority}>{task.priority} (unknown)</option>
        {/if}
      </NativeSelect>
    </div>

    <div class="flex flex-col gap-1">
      <Label for="task-edit-assignee">Who works it</Label>
      <NativeSelect id="task-edit-assignee" bind:value={assignee} disabled={saving}>
        <option value="user">Me</option>
        <option value="agent">The assistant</option>
        {#if task.assignee !== null && !['user', 'agent'].includes(task.assignee)}
          <option value={task.assignee}>{task.assignee} (unknown)</option>
        {/if}
      </NativeSelect>
    </div>

    <div class="flex flex-col gap-1">
      <Label for="task-edit-status">Status</Label>
      <NativeSelect id="task-edit-status" bind:value={status} disabled={saving}>
        {#each options as option (option.value)}
          <option value={option.value}>{option.label}</option>
        {/each}
      </NativeSelect>
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
