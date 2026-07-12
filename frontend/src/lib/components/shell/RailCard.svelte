<script lang="ts">
  import type { Snippet } from 'svelte';

  // Rail card (§10): white card on the panel rail, dot-colored overline,
  // then whatever content the view supplies. `tone` follows the
  // consequence palette — green for real/safe things, amber for the
  // assistant's suggestions/holds, neutral for informational.
  let {
    tone = 'neutral',
    overline,
    children
  }: {
    tone?: 'act' | 'suggest' | 'neutral';
    overline?: string;
    children: Snippet;
  } = $props();

  const DOT_CLASS = {
    act: 'bg-act-dot',
    suggest: 'bg-suggest-dash',
    neutral: 'bg-ink-meta'
  } as const;

  const OVERLINE_CLASS = {
    act: 'text-act',
    suggest: 'text-suggest-ink',
    neutral: ''
  } as const;
</script>

<div class="border-paper-border bg-paper-card shadow-card flex flex-col gap-2 rounded-xl border p-4">
  {#if overline}
    <p class={['text-overline flex items-center gap-1.5', OVERLINE_CLASS[tone]]}>
      <span class={['size-1.5 rounded-full', DOT_CLASS[tone]]} aria-hidden="true"></span>
      {overline}
    </p>
  {/if}
  {@render children()}
</div>
