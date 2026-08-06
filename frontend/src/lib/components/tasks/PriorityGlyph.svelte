<script lang="ts">
  // Priority as a glyph in a fixed 4-unit column, so a scan down the list reads
  // the rank without the word "High" eating title width (redesign spec §List
  // rows). An UNKNOWN priority renders nothing here — `priorityGlyph` returns
  // null for it and the row keeps its verbatim text chip instead, because a
  // glyph would launder a value Valea does not understand.
  import { priorityGlyph } from '$lib/tasks/filters';

  let { priority }: { priority: string | null } = $props();

  const spec = $derived(priorityGlyph(priority));
</script>

{#if spec}
  <!-- `role="img"` is what makes the aria-label reach a screen reader at all:
       a bare <span> is generic, and ARIA forbids naming it. Without it, "‼"
       would be announced as whatever the voice makes of the character. -->
  <span
    class={[
      'w-4 shrink-0 text-center text-[11px] font-bold',
      spec.tone === 'high' ? 'text-warn-ink' : spec.tone === 'medium' ? 'text-warn-dot' : 'text-ink-meta'
    ]}
    role="img"
    aria-label={`priority ${priority}`}
  >{spec.glyph}</span>
{/if}
