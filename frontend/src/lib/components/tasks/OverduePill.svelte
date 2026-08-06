<script lang="ts">
  // The one loud chip in the list (redesign spec §List rows): overdue is the
  // only state that earns a filled terracotta pill, so a row that has slipped
  // reads from across the page while everything else stays quiet text.
  //
  // Tint/ink/border are all tokens, so the pill re-tunes itself in dark mode
  // with the rest of the warn ramp.
  import { overduePillText } from '$lib/tasks/filters';

  let { days }: { days: number } = $props();
</script>

<span
  class="bg-warn-tint text-warn-ink border-warn-border shrink-0 rounded-full border px-2 py-0.5 text-[10.5px] font-semibold tabular-nums"
>
  {overduePillText(days)}
</span>
