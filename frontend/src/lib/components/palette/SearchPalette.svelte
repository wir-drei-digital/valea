<script lang="ts">
  // Cmd+K search palette (Task C9). Mounted once by `+layout.svelte` so it's
  // reachable from anywhere in the app; owns the global `window` keydown
  // listener itself (rather than making the layout own it) so the layout
  // stays a thin "mount points" file.
  //
  // All state transitions run through `paletteReduce` (palette.ts, pure/
  // tested) — this component's own script is only: DOM/keyboard wiring,
  // debounced `api.icmSearch` calls (with a monotonic token to discard a
  // response superseded by a later keystroke — same pattern as the route's
  // `runExternalCheckLoop`/`applyReload` staleness guards), and the
  // synchronous `recentPages()` lookup for the empty-query MRU list.
  //
  // The reactive variable below is deliberately named `paletteState`, not
  // `state` — svelte-check chokes on `let state = $state(...)` (a
  // self-reference error on the `$state` rune itself), so the name is
  // avoided rather than fought.
  import { onMount } from 'svelte';
  import { goto } from '$app/navigation';
  import { page } from '$app/state';
  import { api } from '$lib/api/client';
  import { recentPages } from '$lib/stores/recent-pages';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';
  import { resolveActiveMountKey } from '$lib/shell/icm-route';
  import {
    paletteReduce,
    initialPaletteState,
    highlightSegments,
    type PaletteState,
    type PaletteResultItem
  } from './palette';
  import * as Dialog from '$lib/components/ui/dialog/index.js';
  import { Input } from '$lib/components/ui/input/index.js';
  import { Badge } from '$lib/components/ui/badge/index.js';
  import SearchIcon from '@lucide/svelte/icons/search';

  const SEARCH_DEBOUNCE_MS = 150;

  let paletteState = $state<PaletteState>(initialPaletteState);
  let inputRef = $state<HTMLInputElement | null>(null);

  // Debounce + staleness guard for `api.icmSearch`. `searchTimer` holds the
  // pending debounce; `searchToken` is bumped on every keystroke so a
  // response for a since-superseded query is dropped even if it resolves
  // out of order (a slow first keystroke's search landing after a fast
  // second one's).
  let searchTimer: ReturnType<typeof setTimeout> | null = null;
  let searchToken = 0;

  // Task 9.6: scope `icmSearch` to the ICM the current route is "on" — the
  // SAME resolution `AppFrame.svelte` uses to highlight the sidebar's active
  // ICM group (Task 9.4's `resolveActiveMountKey`, already exercised by
  // `icm-route.test.ts` across every route shape: `/knowledge/<mountKey>/…`,
  // `/chat?session=`, `?icm=`). Cmd+K'ing from inside `coaching`'s Knowledge
  // tree (or its chat) should search `coaching` (+ its declared-related
  // ICMs, per `Valea.ICM.Search`'s scope), not silently return hits from
  // every other mounted ICM. `null` (no route-scoped ICM — e.g. Today, or a
  // route with neither a path nor `?icm=`) falls back to an unscoped,
  // all-mounts search: `icmSearch`'s own default (`mount_key \\ nil` in
  // `Valea.ICM.Search.search/4`) when no mountKey is passed at all.
  const activeMountKey = $derived(
    resolveActiveMountKey(page.url.pathname, page.url.searchParams, recentSessionsStore.groups)
  );

  function basenameNoExt(path: string): string {
    const noExt = path.replace(/\.md$/i, '');
    const idx = noExt.lastIndexOf('/');
    return idx === -1 ? noExt : noExt.slice(idx + 1);
  }

  function recentItems(): PaletteResultItem[] {
    return recentPages().map(({ mountKey, path }) => ({
      path,
      title: basenameNoExt(path),
      mount: mountKey,
      snippet: null,
      terms: []
    }));
  }

  function skippedNoteFor(skipped: string[]): string | null {
    if (skipped.length === 0) return null;
    return `Skipped ${skipped.join(', ')} — took too long to search.`;
  }

  async function runSearch(query: string): Promise<void> {
    const token = ++searchToken;
    const result = await api.icmSearch(query, activeMountKey ?? undefined);
    if (token !== searchToken) return; // a later keystroke already superseded this search

    if (result.ok) {
      const data = result.data as { results: PaletteResultItem[]; skipped: string[] };
      paletteState = paletteReduce(paletteState, {
        type: 'input',
        query,
        results: data.results,
        skippedNote: skippedNoteFor(data.skipped)
      }).state;
    } else {
      paletteState = paletteReduce(paletteState, { type: 'input', query, results: [] }).state;
    }
  }

  function onQueryInput(value: string): void {
    if (searchTimer) clearTimeout(searchTimer);

    const trimmed = value.trim();
    if (trimmed === '') {
      // Empty query → MRU, synchronously (no debounce/network round trip needed).
      searchToken++; // discard any in-flight search's eventual response
      paletteState = paletteReduce(paletteState, { type: 'input', query: value, results: recentItems() }).state;
      return;
    }

    // Reflect the typed text immediately, clearing stale results, then
    // debounce the actual search — same shape as the [[ picker's
    // `page_link_suggestion.js` debounce.
    paletteState = paletteReduce(paletteState, { type: 'input', query: value, results: [] }).state;
    searchTimer = setTimeout(() => {
      searchTimer = null;
      void runSearch(value);
    }, SEARCH_DEBOUNCE_MS);
  }

  function openPalette(): void {
    paletteState = paletteReduce(paletteState, { type: 'open' }).state;
    paletteState = paletteReduce(paletteState, { type: 'input', query: '', results: recentItems() }).state;
  }

  function closePalette(): void {
    if (searchTimer) {
      clearTimeout(searchTimer);
      searchTimer = null;
    }
    searchToken++;
    paletteState = paletteReduce(paletteState, { type: 'close' }).state;
  }

  function togglePalette(): void {
    if (paletteState.open) closePalette();
    else openPalette();
  }

  /**
   * `EXCEPT the editor` (spec): a click/focus inside the tiptap editor
   * (`.page-editor`'s contenteditable host) must NOT block Cmd+K — the
   * palette opens right over it. Any OTHER text input/textarea/
   * contenteditable (a dialog's Input, etc.) does block it, so Cmd+K
   * doesn't hijack normal text editing there.
   */
  function isBlockingEditableTarget(target: EventTarget | null): boolean {
    if (!(target instanceof HTMLElement)) return false;
    if (target.tagName === 'INPUT' || target.tagName === 'TEXTAREA') return true;
    if (target.isContentEditable) return target.closest('.page-editor') === null;
    return false;
  }

  function onWindowKeydown(event: KeyboardEvent): void {
    const isToggleCombo = (event.metaKey || event.ctrlKey) && event.key.toLowerCase() === 'k';
    if (!isToggleCombo) return;
    // While already open, Cmd+K always closes — including from inside the
    // palette's own search input, which IS an <input> and would otherwise
    // match the editable-target guard below.
    if (!paletteState.open && isBlockingEditableTarget(event.target)) return;

    event.preventDefault();
    togglePalette();
  }

  onMount(() => {
    window.addEventListener('keydown', onWindowKeydown);
    return () => window.removeEventListener('keydown', onWindowKeydown);
  });

  function onInputKeydown(event: KeyboardEvent): void {
    if (event.key === 'ArrowDown') {
      event.preventDefault();
      paletteState = paletteReduce(paletteState, { type: 'arrow', direction: 'down' }).state;
    } else if (event.key === 'ArrowUp') {
      event.preventDefault();
      paletteState = paletteReduce(paletteState, { type: 'arrow', direction: 'up' }).state;
    } else if (event.key === 'Enter') {
      event.preventDefault();
      const result = paletteReduce(paletteState, { type: 'enter' });
      paletteState = result.state;
      if (result.goto) {
        const dest = result.goto;
        closePalette();
        void goto(dest);
      }
    }
    // Escape is handled by the underlying Dialog (bits-ui's EscapeLayer) via onOpenChange below.
  }

  function chooseItem(index: number): void {
    paletteState = { ...paletteState, active: index };
    const result = paletteReduce(paletteState, { type: 'enter' });
    paletteState = result.state;
    if (result.goto) {
      const dest = result.goto;
      closePalette();
      void goto(dest);
    }
  }
</script>

<Dialog.Root
  open={paletteState.open}
  onOpenChange={(open) => {
    if (!open) closePalette();
  }}
>
  <Dialog.Content
    class="top-[18%] max-w-[calc(100%-2rem)] translate-y-0 gap-0 overflow-hidden p-0 sm:max-w-lg"
    showCloseButton={false}
    onOpenAutoFocus={(event) => {
      event.preventDefault();
      inputRef?.focus();
    }}
  >
    <div class="border-paper-hairline flex items-center gap-2 border-b px-3.5 py-2.5">
      <SearchIcon class="text-ink-meta size-4 shrink-0" strokeWidth={1.5} aria-hidden="true" />
      <Input
        bind:ref={inputRef}
        value={paletteState.query}
        oninput={(event) => onQueryInput((event.currentTarget as HTMLInputElement).value)}
        onkeydown={onInputKeydown}
        placeholder="Search pages…"
        class="h-7 border-none bg-transparent px-0 shadow-none focus-visible:ring-0"
        aria-label="Search knowledge pages"
      />
    </div>

    {#if paletteState.skippedNote}
      <p class="text-ink-meta border-paper-hairline border-b px-3.5 py-1.5 text-[11.5px]">
        {paletteState.skippedNote}
      </p>
    {/if}

    <ul class="max-h-[min(60vh,26rem)] overflow-y-auto py-1.5">
      {#if paletteState.results.length === 0}
        <li class="text-ink-meta px-3.5 py-3 text-[12.5px]">
          {paletteState.query.trim() === '' ? 'No recent pages yet.' : 'No matching pages.'}
        </li>
      {/if}
      {#each paletteState.results as result, index (result.path)}
        <li>
          <button
            type="button"
            class="flex w-full flex-col gap-0.5 px-3.5 py-2 text-left transition-colors"
            class:bg-paper-pill={index === paletteState.active}
            onmouseenter={() => (paletteState = { ...paletteState, active: index })}
            onclick={() => chooseItem(index)}
          >
            <span class="flex items-center gap-2">
              <span class="text-ink-heading min-w-0 flex-1 truncate text-[13.5px] font-medium">
                {#each highlightSegments(result.title, result.terms) as seg, i (i)}
                  {#if seg.bold}<strong>{seg.text}</strong>{:else}{seg.text}{/if}
                {/each}
              </span>
              {#if result.mount}
                <Badge variant="outline" class="shrink-0">{result.mount}</Badge>
              {/if}
            </span>
            {#if result.snippet}
              <span class="text-ink-secondary truncate text-[12px]">
                {#each highlightSegments(result.snippet, result.terms) as seg, i (i)}
                  {#if seg.bold}<strong>{seg.text}</strong>{:else}{seg.text}{/if}
                {/each}
              </span>
            {/if}
            <span class="text-ink-meta truncate font-mono text-[11px]">{result.path}</span>
          </button>
        </li>
      {/each}
    </ul>
  </Dialog.Content>
</Dialog.Root>
