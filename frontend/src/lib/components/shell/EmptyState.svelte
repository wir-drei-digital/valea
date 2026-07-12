<script lang="ts">
  import type { Component } from 'svelte';

  // Calm placeholder for routes whose real content lands in a later step, or
  // whose main pane has nothing selected yet (§3 voice: plain language, no
  // exclamation marks). Icon + one Newsreader line + one body line, plus an
  // optional `actions` snippet for the rare case a route needs a next step
  // from the empty state itself (e.g. Chat's "Start a session" / "Run
  // checks"). Every existing call site omits `actions` and is unaffected.
  // A small procedural garden grows quietly underneath — see PlantGrowth.
  import type { Snippet } from 'svelte';
  import PlantGrowth from './PlantGrowth.svelte';

  let {
    icon,
    title,
    body,
    actions
  }: {
    icon: Component<Record<string, unknown>>;
    title: string;
    body: string;
    actions?: Snippet;
  } = $props();

  const Icon = $derived(icon);
</script>

<div class="flex flex-col items-start gap-3 py-10">
  <div
    class="flex size-10 items-center justify-center rounded-full bg-paper-pill text-ink-secondary"
    aria-hidden="true"
  >
    <Icon class="size-[18px]" strokeWidth={1.5} />
  </div>
  <h1 class="font-display text-[21px] text-ink-heading">{title}</h1>
  <p class="max-w-[480px] text-[13.5px] text-ink-body">{body}</p>
  {#if actions}
    <div class="mt-1 flex items-center gap-3">
      {@render actions()}
    </div>
  {/if}
  <div class="mt-3" aria-hidden="true">
    <PlantGrowth />
  </div>
</div>
