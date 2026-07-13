/**
 * Pure state machine for the Cmd+K search palette (Task C9). No I/O — the
 * impure caller is `SearchPalette.svelte`, which owns `window` keydown
 * wiring, debounced `api.icmSearch` calls, and `recentPages()` lookups (for
 * the empty-query MRU list), and feeds their results into this reducer via
 * the `input` event.
 *
 * `input` doubles as "the query text changed" AND "here are the results for
 * it" — there's no separate "query changed" event, since the two are never
 * meaningfully out of sync from this module's point of view: the caller
 * dispatches `input` with the freshly-typed query and an empty `results`
 * array the instant the user types (so the visible text updates and stale
 * results disappear immediately), then dispatches `input` again with the
 * same query and the resolved results once the (debounced, possibly async)
 * search/MRU lookup settles. A response for a since-superseded query is the
 * caller's problem to discard (compare against the live input value before
 * dispatching) — this reducer has no way to reject a stale `input` itself,
 * since by design it doesn't remember what query a given search was fired
 * for.
 */

import { encodePath } from '$lib/shell/nav';

export type PaletteResultItem = {
  path: string;
  title: string;
  /** `null` for an MRU-derived row (Task C9 doesn't look up a path's mount just to render the palette). */
  mount: string | null;
  /** `null` for an MRU-derived row (no search snippet to show). */
  snippet: string | null;
  /** The (lowercased) search terms this row matched — `[]` for an MRU-derived row. Feeds `highlightSegments`. */
  terms: string[];
};

export type PaletteState = {
  open: boolean;
  query: string;
  results: PaletteResultItem[];
  /** A human-readable "Skipped <mounts> (took too long to search)." line, or `null`. */
  skippedNote: string | null;
  /** Index into `results` of the keyboard-selected row; `-1` when nothing is selected (empty results). */
  active: number;
};

export type PaletteEvent =
  | { type: 'open' }
  | { type: 'close' }
  | { type: 'input'; query: string; results: PaletteResultItem[]; skippedNote?: string | null }
  | { type: 'arrow'; direction: 'up' | 'down' }
  | { type: 'enter' };

export type PaletteReduceResult = {
  state: PaletteState;
  /** Only set by `enter`, and only when a result is actually selected — the URL to `goto()`. */
  goto?: string;
};

export const initialPaletteState: PaletteState = {
  open: false,
  query: '',
  results: [],
  skippedNote: null,
  active: -1
};

export function paletteReduce(state: PaletteState, event: PaletteEvent): PaletteReduceResult {
  switch (event.type) {
    case 'open':
      return { state: { open: true, query: '', results: [], skippedNote: null, active: -1 } };

    case 'close':
      return { state: initialPaletteState };

    case 'input':
      return {
        state: {
          ...state,
          query: event.query,
          results: event.results,
          skippedNote: event.skippedNote ?? null,
          active: event.results.length > 0 ? 0 : -1
        }
      };

    case 'arrow': {
      const count = state.results.length;
      if (count === 0) return { state };

      const delta = event.direction === 'down' ? 1 : -1;
      const next = (state.active + delta + count) % count;
      return { state: { ...state, active: next } };
    }

    case 'enter': {
      const item = state.results[state.active];
      if (!item) return { state };

      return {
        state: { ...state, open: false },
        goto: `/knowledge/${encodePath(item.path)}`
      };
    }
  }
}

// -- result-row highlighting -----------------------------------------------

export type HighlightSegment = { text: string; bold: boolean };

/**
 * Splits `text` into plain/matched segments for a row's title or snippet,
 * so `SearchPalette.svelte` can bold each matched term by rendering
 * `{#if seg.bold}<strong>{seg.text}</strong>{:else}{seg.text}{/if}` —
 * `snippet`/`title` come straight from a page's own content (or the user's
 * search text via `terms`), so this deliberately returns plain strings for
 * the caller to render as TEXT, never markup, keeping `{@html}` (and the
 * XSS surface it'd open on arbitrary page content) out of the picture
 * entirely.
 *
 * Matching mirrors the backend's own (`Valea.ICM.Search.score_file/6`):
 * case-insensitive substring, not whole-word — a `terms` entry of "meet"
 * highlights inside "meeting" too, exactly like the scan that produced this
 * row in the first place. Overlapping/adjacent matches (two terms hitting
 * the same span, or back-to-back matches) are merged into one bold run
 * rather than emitting empty segments between them.
 */
export function highlightSegments(text: string, terms: string[]): HighlightSegment[] {
  const cleanTerms = terms.map((t) => t.trim().toLowerCase()).filter((t) => t.length > 0);
  if (cleanTerms.length === 0) return [{ text, bold: false }];

  const lower = text.toLowerCase();
  const ranges: [number, number][] = [];
  for (const needle of cleanTerms) {
    let from = 0;
    for (;;) {
      const idx = lower.indexOf(needle, from);
      if (idx === -1) break;
      ranges.push([idx, idx + needle.length]);
      from = idx + needle.length;
    }
  }
  if (ranges.length === 0) return [{ text, bold: false }];

  ranges.sort((a, b) => a[0] - b[0]);
  const merged: [number, number][] = [];
  for (const [start, end] of ranges) {
    const last = merged[merged.length - 1];
    if (last && start <= last[1]) {
      last[1] = Math.max(last[1], end);
    } else {
      merged.push([start, end]);
    }
  }

  const segments: HighlightSegment[] = [];
  let cursor = 0;
  for (const [start, end] of merged) {
    if (start > cursor) segments.push({ text: text.slice(cursor, start), bold: false });
    segments.push({ text: text.slice(start, end), bold: true });
    cursor = end;
  }
  if (cursor < text.length) segments.push({ text: text.slice(cursor), bold: false });

  return segments;
}
