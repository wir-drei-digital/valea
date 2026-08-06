<script lang="ts">
  // One ICM's morning briefing (redesign spec §Today → From your agent): the
  // `today.json` file the project's agent maintains at its root. Valea NEVER
  // writes that file (`Valea.Cockpit.today/0`'s moduledoc) — this card is a
  // reader, which is exactly why it is boxed and labelled by provenance: it is
  // the one region of Today whose words came from somewhere else.
  //
  // Renders sections whose `todayJson` is `present` ONLY. `unreadable` gets the
  // route's calm one-liner and `absent` gets nothing at all — neither is a card,
  // so neither is this component's business; the caller filters.
  import { knowledgeHref } from '$lib/shell/nav';
  import { mountProvenanceLabel } from '$lib/shell/provenance';
  import type { TodaySection } from '$lib/today/cockpit';
  import { formatTimestamp } from '$lib/today/today-view';

  let { section }: { section: TodaySection } = $props();

  // The mount key backstops a blank manifest name (a stale cache, or a
  // defensively-blank manifest) — same fallback the route's `unreadable` note
  // takes, so the two never disagree about what a project is called. `null`
  // only if BOTH are blank, and the overline then names no project rather than
  // trailing a bare "·"; the label arrives already carrying its separator.
  const provenance = $derived(mountProvenanceLabel(section.icmName || section.mountKey));

  /**
   * A `today.json` that parses to `{}` is `present` and says nothing. Rendering
   * it would put an empty tinted box on the page under a heading promising a
   * briefing — the same "standing alarm about nothing" `AttentionCard` refuses,
   * in the quieter register. The state is still not `absent`, and Task 11's
   * whole-page empty state is what speaks for a workspace with nothing in it.
   *
   * Truthiness, not `!== null`: `"notes": ""` normalizes to an empty STRING,
   * which the body below renders as nothing just like a missing key. The guard
   * has to agree with what actually paints, or the empty box comes back for the
   * one file that spells its emptiness out.
   */
  const hasBriefing = $derived(Boolean(section.notes) || section.prepared.length > 0);
</script>

{#if hasBriefing}
  <!-- `text-overline` uppercases in CSS, so the source case here is cosmetic. -->
  <section class="border-paper-border bg-paper-card rounded-xl border p-4">
    <h2 class="text-overline flex flex-wrap items-baseline gap-x-1">
      <span>FROM YOUR AGENT{provenance ? ` ${provenance}` : ''}</span>
      {#if section.updatedAt}
        <span class="tabular-nums">· updated {formatTimestamp(section.updatedAt)}</span>
      {/if}
    </h2>

    {#if section.notes}
      <p class="text-ink-body mt-2 text-[13.5px] leading-relaxed">{section.notes}</p>
    {/if}

    {#if section.prepared.length > 0}
      <!-- Prepared work: a title that links into Knowledge when the entry names a
           page, plain text when it doesn't (the agent may prepare something that
           has no page yet). No index key is available — entries carry no id. -->
      <ul class="mt-3 flex flex-col gap-3">
        {#each section.prepared as item, i (i)}
          <li>
            {#if item.page}
              <a
                href={knowledgeHref(section.mountKey, item.page)}
                class="text-ink-heading text-[13.5px] font-medium hover:underline"
              >
                {item.title ?? '(untitled)'}
              </a>
            {:else}
              <p class="text-ink-heading text-[13.5px] font-medium">{item.title ?? '(untitled)'}</p>
            {/if}
            {#if item.summary}
              <p class="text-ink-body text-[13px]">{item.summary}</p>
            {/if}
          </li>
        {/each}
      </ul>
    {/if}
  </section>
{/if}
