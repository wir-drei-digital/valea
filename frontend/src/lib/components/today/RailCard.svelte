<script lang="ts">
  // The rail's chrome (redesign spec §Rail): a quiet card with an overline and
  // whatever the caller puts in it. The rail is the page's THIRD and last
  // sanctioned box — `AttentionCard` (tinted, one interrupt) and
  // `AgentBriefingCard` (the agent's words) are the other two; everything else
  // on Today is plain column.
  //
  // Padding is `p-3.5` rather than the columns' `p-4`: the rail is 300px wide
  // and every millimetre it spends on its own frame comes out of a sender name
  // or a session title.
  //
  // The card does NOT guard on emptiness the way `AttentionCard` does. Each of
  // the three callers owns a different "empty" (no configured accounts, no
  // registered notices, no recent sessions), and a component that cannot see
  // inside a children snippet cannot answer that question for them.
  import type { Snippet } from 'svelte';

  let { overline, children }: { overline: string; children: Snippet } = $props();
</script>

<section class="bg-paper-card border-paper-border rounded-xl border p-3.5">
  <!-- `text-overline` uppercases in CSS, so the source case here is cosmetic. -->
  <h2 class="text-overline mb-2">{overline}</h2>
  {@render children()}
</section>
