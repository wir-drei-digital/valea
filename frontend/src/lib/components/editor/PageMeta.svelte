<script lang="ts">
  // Save-status + context-cost line for the page route header. Presentational
  // only — the route owns computing `savedAt`/`tokens` and reading `state`
  // off the `PageEditorStore` instance.
  import type { PageEditorState } from '$lib/stores/page-editor.svelte';

  let { state, savedAt, tokens }: { state: PageEditorState; savedAt: string | null; tokens: number } =
    $props();

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
</script>

{#if state !== 'conflict'}
  <p class="text-ink-meta text-[12px]" data-testid="page-meta">
    {#if saveStatus}
      <span class={state === 'dirty' ? 'text-suggest-ink' : ''}>{saveStatus}</span>
      <span aria-hidden="true"> · </span>
    {/if}
    <span>~{tokens} tokens</span>
  </p>
{/if}
