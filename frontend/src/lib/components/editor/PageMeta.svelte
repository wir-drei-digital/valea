<script lang="ts">
  // Save-status + context-cost line for the page route header, PLUS
  // (independently) the read-only "Contract" facts block for a workflow
  // page's frontmatter. Two unrelated pieces of "page meta" share this file
  // because they're both small, presentational, and owned by the same
  // route — but they render as two separate top-level fragments so the
  // route can place the Contract block wherever it needs to (see
  // `+page.svelte`, which renders a `state`-only call in the header and a
  // `frontmatter`-only call further down, above the ownership card).
  import type { PageEditorState } from '$lib/stores/page-editor.svelte';
  import SectionOverline from '$lib/components/shell/SectionOverline.svelte';
  import { contractRowsFor } from './contract-rows';

  let {
    state,
    savedAt,
    tokens,
    frontmatter = null
  }: {
    state?: PageEditorState;
    savedAt?: string | null;
    tokens?: number;
    frontmatter?: Record<string, unknown> | null;
  } = $props();

  function formatSavedAt(iso: string): string {
    const parsed = new Date(iso);
    if (Number.isNaN(parsed.getTime())) return '';
    return parsed.toLocaleTimeString(undefined, { hour: '2-digit', minute: '2-digit' });
  }

  // `null` while `conflict` — the ConflictBanner already says the page needs
  // attention, so the meta line goes quiet instead of showing a stale
  // "Saved"/"Unsaved" that would contradict the banner.
  const saveStatus = $derived.by((): string | null => {
    if (state === 'saving') return 'Saving…';
    if (state === 'dirty') return 'Unsaved';
    if (state === 'conflict') return null;
    return savedAt ? `Saved · ${formatSavedAt(savedAt)}` : null;
  });

  // Design system §8 "structured facts": label column `#948A75`
  // (`--ink-meta`), value 600-weight ink. Facts the assistant may quote
  // verbatim live here, not in prose — and there's no editing affordance:
  // the contract is edited as markdown/YAML in the raw view, not through
  // this summary.
  const contractRows = $derived(contractRowsFor(frontmatter));
</script>

{#if state !== undefined && state !== 'conflict'}
  <p class="text-ink-meta text-[12px]" data-testid="page-meta">
    {#if saveStatus}
      <span class={state === 'dirty' ? 'text-suggest-ink' : ''}>{saveStatus}</span>
      <span aria-hidden="true"> · </span>
    {/if}
    <span>~{tokens} tokens</span>
  </p>
{/if}

{#if contractRows.length > 0}
  <div data-testid="page-contract">
    <SectionOverline label="Contract" />
    <dl class="flex flex-col gap-1.5 px-2 pb-2">
      {#each contractRows as row (row.label)}
        <div class="flex items-baseline justify-between gap-4 text-[13px]">
          <dt class="text-ink-meta">{row.label}</dt>
          <dd class="text-ink-heading font-semibold">{row.value}</dd>
        </div>
      {/each}
    </dl>
  </div>
{/if}
