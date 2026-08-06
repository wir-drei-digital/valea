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

  // `null` for a blank manifest name (a stale cache, or a defensively-blank
  // manifest) — the overline then names no project rather than trailing a bare
  // "·". The label arrives already carrying its separator.
  const provenance = $derived(mountProvenanceLabel(section.icmName));
</script>

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
