<script lang="ts">
  // Create/edit panel for Valea-calendar events (Spec F §UI): title,
  // start/end OR all-day, location, description. The editor SPEAKS
  // INCLUSIVE dates for all-day events and converts to/from the RFC 5545
  // exclusive end at the RPC boundary (spec §The Valea calendar). Timed
  // inputs are `datetime-local` (host-zone wall time) converted to UTC ISO
  // instants for the wire.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Label } from '$lib/components/ui/label/index.js';
  import { calendarStore } from '$lib/stores/calendar.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';
  import { localParts, type CalendarOccurrence } from './calendar-shapes';

  let {
    initial = null,
    onClose,
    onSaved
  }: {
    /** `null` → create; an occurrence (valea) → edit that event file. */
    initial?: CalendarOccurrence | null;
    onClose: () => void;
    onSaved: () => void;
  } = $props();

  const editing = $derived(initial !== null);
  const initialName = $derived(
    initial?.path ? (initial.path.split('/').pop() ?? '').replace(/\.md$/, '') : ''
  );

  const zone = Intl.DateTimeFormat().resolvedOptions().timeZone;

  function toLocalInput(isoUtc: string): string {
    const parts = localParts(isoUtc, zone);
    const h = String(Math.floor(parts.minutes / 60)).padStart(2, '0');
    const m = String(parts.minutes % 60).padStart(2, '0');
    return `${parts.day}T${h}:${m}`;
  }

  /** Exclusive wire date → inclusive editor date (and `fromInclusive` inverts it). */
  function toInclusive(exclusive: string): string {
    return shiftDate(exclusive, -1);
  }

  function fromInclusive(inclusive: string): string {
    return shiftDate(inclusive, 1);
  }

  function shiftDate(key: string, days: number): string {
    const [y, m, d] = key.split('-').map(Number);
    const date = new Date(y, m - 1, d + days);
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`;
  }

  let name = $state('');
  let title = $state('');
  let allDay = $state(false);
  let start = $state('');
  let end = $state('');
  let location = $state('');
  let status = $state('confirmed');
  let description = $state('');

  // Seed from the occurrence being edited (runs once — `initial` never
  // changes for an open panel; the route remounts per selection).
  $effect.pre(() => {
    if (!initial) return;
    name = initialName;
    title = initial.summary;
    allDay = initial.all_day;
    location = initial.location ?? '';
    status = initial.status;
    description = initial.description ?? '';
    if (initial.all_day) {
      start = initial.start;
      end = toInclusive(initial.end);
    } else {
      start = toLocalInput(initial.start);
      end = toLocalInput(initial.end);
    }
  });

  let saving = $state(false);
  let error: string | null = $state(null);

  async function save(): Promise<void> {
    error = null;
    if (!title.trim()) {
      error = 'Title is required.';
      return;
    }
    if (!editing && !/^[a-z0-9][a-z0-9._-]{0,79}$/.test(name)) {
      error = 'Name must be lowercase letters, digits, dots, dashes or underscores.';
      return;
    }
    if (!start) {
      error = 'Start is required.';
      return;
    }

    const attrs = allDay
      ? {
          title: title.trim(),
          start,
          end: end ? fromInclusive(end) : null,
          allDay: true,
          location: location.trim() || null,
          status,
          description: description || null
        }
      : {
          title: title.trim(),
          start: new Date(start).toISOString().replace(/\.\d{3}Z$/, 'Z'),
          end: end ? new Date(end).toISOString().replace(/\.\d{3}Z$/, 'Z') : null,
          allDay: false,
          location: location.trim() || null,
          status,
          description: description || null
        };

    saving = true;
    const generation = workspaceStore.generation ?? 0;
    const failure = editing
      ? await calendarStore.updateEvent(name, attrs, generation)
      : await calendarStore.createEvent(name, attrs, generation);
    saving = false;
    if (failure) {
      error = failure;
      return;
    }
    onSaved();
  }
</script>

<div
  class="border-paper-hairline bg-paper-card absolute top-16 right-7 z-20 flex w-96 flex-col gap-3 rounded-[9px] border p-4 shadow-lg"
  role="dialog"
  aria-label={editing ? 'Edit event' : 'New event'}
>
  <p class="text-ink-heading text-[14px] font-semibold">{editing ? 'Edit event' : 'New event'}</p>

  {#if !editing}
    <div class="flex flex-col gap-1">
      <Label for="cal-ev-name">Name (file name)</Label>
      <Input id="cal-ev-name" type="text" bind:value={name} placeholder="coffee-with-priya" />
    </div>
  {/if}

  <div class="flex flex-col gap-1">
    <Label for="cal-ev-title">Title</Label>
    <Input id="cal-ev-title" type="text" bind:value={title} placeholder="Coffee with Priya" />
  </div>

  <label class="text-ink-body flex items-center gap-2 text-[12.5px]">
    <input type="checkbox" bind:checked={allDay} />
    All-day
  </label>

  <div class="flex items-center gap-2">
    <div class="flex flex-1 flex-col gap-1">
      <Label for="cal-ev-start">Start</Label>
      {#if allDay}
        <Input id="cal-ev-start" type="date" bind:value={start} />
      {:else}
        <Input id="cal-ev-start" type="datetime-local" bind:value={start} />
      {/if}
    </div>
    <div class="flex flex-1 flex-col gap-1">
      <Label for="cal-ev-end">End{allDay ? ' (inclusive)' : ''}</Label>
      {#if allDay}
        <Input id="cal-ev-end" type="date" bind:value={end} />
      {:else}
        <Input id="cal-ev-end" type="datetime-local" bind:value={end} />
      {/if}
    </div>
  </div>

  <div class="flex flex-col gap-1">
    <Label for="cal-ev-location">Location</Label>
    <Input id="cal-ev-location" type="text" bind:value={location} placeholder="Café Anton" />
  </div>

  <div class="flex flex-col gap-1">
    <Label for="cal-ev-status">Status</Label>
    <select id="cal-ev-status" class="border-paper-hairline bg-paper-surface rounded-[7px] border px-2 py-1.5 text-[12.5px]" bind:value={status}>
      <option value="confirmed">Confirmed</option>
      <option value="tentative">Tentative</option>
      <option value="cancelled">Cancelled</option>
    </select>
  </div>

  <div class="flex flex-col gap-1">
    <Label for="cal-ev-description">Description</Label>
    <textarea
      id="cal-ev-description"
      class="border-paper-hairline bg-paper-surface min-h-16 rounded-[7px] border px-2 py-1.5 text-[12.5px]"
      bind:value={description}
    ></textarea>
  </div>

  {#if error}
    <p class="text-warn-ink text-[11.5px]">{error}</p>
  {/if}

  <div class="flex items-center justify-end gap-2">
    <Button type="button" variant="ghost" size="sm" onclick={onClose}>Cancel</Button>
    <Button type="button" size="sm" disabled={saving} onclick={save}>
      {editing ? 'Save changes' : 'Create event'}
    </Button>
  </div>
</div>
