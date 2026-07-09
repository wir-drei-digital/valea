<script lang="ts">
  import type { Component } from 'svelte';

  // Calm placeholder for routes whose real content lands in a later step
  // (§3 voice: plain language, no exclamation marks). Icon + one Newsreader
  // line + one body line — deliberately no buttons, nothing to click yet.
  let {
    icon,
    title,
    body
  }: {
    icon: Component<Record<string, unknown>>;
    title: string;
    body: string;
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
</div>
