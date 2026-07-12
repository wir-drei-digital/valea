<script lang="ts">
  // One event chip in the grid — §9 vocabulary is the whole contract:
  // solid fill + 3px green bar = real; solid neutral = block; dashed amber
  // = the assistant's hand (never committed); green outline = routine.
  // Radius 7 per the geometry spec ("7px list rows & events"). The card
  // fills the absolutely-positioned box its parent lays out; text that
  // doesn't fit a short event is clipped, title first in the stack.
  import {
    timeRangeLabel,
    type CalendarEvent as CalendarEventShape
  } from './calendar-shapes';

  let { event, past = false }: { event: CalendarEventShape; past?: boolean } = $props();

  const KIND_CLASS: Record<CalendarEventShape['kind'], string> = {
    booked: 'border-l-[3px] border-act bg-act-tint',
    block: 'bg-paper-track',
    hold: 'border-[1.5px] border-dashed border-suggest-dash bg-paper-surface',
    routine: 'border-[1.5px] border-act bg-paper-card'
  };

  const TITLE_CLASS: Record<CalendarEventShape['kind'], string> = {
    booked: 'text-ink-heading',
    block: 'text-ink-secondary',
    hold: 'text-suggest-ink',
    routine: 'text-ink-heading'
  };

  const timeLine = $derived(
    [timeRangeLabel(event.startMin, event.endMin), event.detail].filter(Boolean).join(' · ')
  );
</script>

<div
  class={[
    'flex h-full flex-col gap-0.5 overflow-hidden rounded-[7px] px-2 py-1.5',
    KIND_CLASS[event.kind],
    past && 'opacity-55'
  ]}
>
  <p class={['truncate text-[12px] leading-tight [font-weight:650]', TITLE_CLASS[event.kind]]}>
    {event.title}
  </p>
  <p class={['truncate text-[10.5px] leading-tight', event.kind === 'hold' ? 'text-suggest-ink' : 'text-ink-subtitle']}>
    {timeLine}
  </p>
</div>
