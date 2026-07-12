<script lang="ts">
  import type { Snippet } from 'svelte';

  // Main-pane page header (§11: "overline → Newsreader title → one-line
  // subtitle; never boxed section headers"). Shared by document-like pages
  // (Workflows, Audit log, Knowledge) so they stop hand-rolling the same
  // three lines with drifting sizes. Today's greeting (36px) and the
  // memory-page header (30px + meta row) stay bespoke — they are their own
  // §3 scale roles.
  let {
    overline,
    title,
    subtitle,
    children
  }: {
    overline?: string;
    title: string;
    subtitle?: string;
    /** Optional extra row (meta line, actions) rendered inside the header. */
    children?: Snippet;
  } = $props();
</script>

<header class="flex flex-col gap-2 pb-2">
  {#if overline}
    <p class="text-overline">{overline}</p>
  {/if}
  <h1 class="font-display text-ink-heading text-[24px] leading-tight font-medium">{title}</h1>
  {#if subtitle}
    <p class="text-ink-body max-w-[560px] text-[13.5px]">{subtitle}</p>
  {/if}
  {#if children}
    {@render children()}
  {/if}
</header>
