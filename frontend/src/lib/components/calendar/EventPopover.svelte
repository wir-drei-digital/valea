<script lang="ts">
  // Detail popover for a selected occurrence (Spec F §UI): external events
  // are read-only (title, local time, location, source, description); valea
  // events add Edit + typed-confirm Delete. Rendered as a floating card by
  // the route — one open popover at a time, closed on any action.
  import { Button } from '$lib/components/ui/button/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import X from '@lucide/svelte/icons/x';
  import { localParts, timeLabel, type CalendarOccurrence } from './calendar-shapes';
  import { calendarStore } from '$lib/stores/calendar.svelte';
  import { workspaceStore } from '$lib/stores/workspace.svelte';

  let {
    occurrence,
    zone,
    onClose,
    onEdit
  }: {
    occurrence: CalendarOccurrence;
    zone: string;
    onClose: () => void;
    /** Valea events only — opens the editor pre-filled. */
    onEdit?: (occurrence: CalendarOccurrence) => void;
  } = $props();

  const isValea = $derived(occurrence.source === 'valea');
  /** Valea event NAME = file basename without `.md` — the RPC identifier for update/delete. */
  const valeaName = $derived(
    occurrence.path ? (occurrence.path.split('/').pop() ?? '').replace(/\.md$/, '') : null
  );

  const timeLine = $derived.by(() => {
    if (occurrence.all_day) {
      // Exclusive wire end → inclusive display dates.
      return occurrence.start === inclusiveEnd(occurrence.end)
        ? `${occurrence.start} · all day`
        : `${occurrence.start} – ${inclusiveEnd(occurrence.end)} · all day`;
    }
    const start = localParts(occurrence.start, zone);
    const end = localParts(occurrence.end, zone);
    const endLabel = start.day === end.day ? timeLabel(end.minutes) : `${end.day} ${timeLabel(end.minutes)}`;
    return `${start.day} ${timeLabel(start.minutes)} – ${endLabel}`;
  });

  function inclusiveEnd(exclusive: string): string {
    const [y, m, d] = exclusive.split('-').map(Number);
    const date = new Date(y, m - 1, d - 1);
    const mm = String(date.getMonth() + 1).padStart(2, '0');
    const dd = String(date.getDate()).padStart(2, '0');
    return `${date.getFullYear()}-${mm}-${dd}`;
  }

  let confirmingDelete = $state(false);
  let confirmText = $state('');
  let deleteError: string | null = $state(null);
  let deleting = $state(false);

  async function deleteEvent(): Promise<void> {
    if (!valeaName) return;
    deleting = true;
    deleteError = null;
    const error = await calendarStore.deleteEvent(valeaName, confirmText, workspaceStore.generation ?? 0);
    deleting = false;
    if (error) {
      deleteError = error;
      return;
    }
    onClose();
  }
</script>

<div
  class="border-paper-hairline bg-paper-card absolute top-16 right-7 z-20 w-80 rounded-[9px] border p-4 shadow-lg"
  role="dialog"
  aria-label="Event details"
>
  <div class="flex items-start justify-between gap-2">
    <p class={['text-ink-heading text-[14px] font-semibold', occurrence.status === 'cancelled' && 'line-through']}>
      {occurrence.summary}
    </p>
    <Button type="button" variant="ghost" size="icon-sm" aria-label="Close" onclick={onClose}>
      <X strokeWidth={1.5} />
    </Button>
  </div>

  <p class="text-ink-subtitle mt-1 text-[12px] tabular-nums">{timeLine}</p>
  {#if occurrence.location}
    <p class="text-ink-body mt-1 text-[12px]">{occurrence.location}</p>
  {/if}
  <p class="text-ink-meta mt-1 text-[11.5px]">
    {isValea ? 'Valea calendar' : occurrence.source}
    {#if occurrence.status === 'tentative'}· tentative{/if}
    {#if occurrence.status === 'cancelled'}· cancelled{/if}
  </p>
  {#if occurrence.description}
    <p class="text-ink-body mt-2 text-[12.5px] leading-relaxed whitespace-pre-wrap">{occurrence.description}</p>
  {/if}

  {#if isValea && valeaName}
    <div class="border-paper-hairline mt-3 flex items-center gap-2 border-t pt-3">
      <Button type="button" variant="outline" size="sm" onclick={() => onEdit?.(occurrence)}>Edit</Button>
      {#if !confirmingDelete}
        <Button type="button" variant="outline" size="sm" onclick={() => (confirmingDelete = true)}>Delete…</Button>
      {/if}
    </div>
    {#if confirmingDelete}
      <div class="mt-2 flex flex-col gap-2">
        <p class="text-ink-meta text-[11.5px]">Type <span class="font-mono">{valeaName}</span> to delete this event.</p>
        <Input type="text" bind:value={confirmText} placeholder={valeaName} aria-label="Delete confirmation" />
        <div class="flex items-center gap-2">
          <Button
            type="button"
            variant="destructive"
            size="sm"
            disabled={confirmText !== valeaName || deleting}
            onclick={deleteEvent}
          >
            Delete event
          </Button>
          <Button type="button" variant="ghost" size="sm" onclick={() => (confirmingDelete = false)}>Cancel</Button>
        </div>
        {#if deleteError}
          <p class="text-warn-ink text-[11.5px]">{deleteError}</p>
        {/if}
      </div>
    {/if}
  {/if}
</div>
