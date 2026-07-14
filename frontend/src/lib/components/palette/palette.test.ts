import { describe, it, expect } from 'vitest';
import {
  paletteReduce,
  initialPaletteState,
  highlightSegments,
  type PaletteResultItem,
  type PaletteState
} from './palette';

function item(overrides: Partial<PaletteResultItem> = {}): PaletteResultItem {
  return {
    path: 'Notes/A.md',
    title: 'A',
    mount: 'main',
    snippet: 'a snippet',
    terms: [],
    ...overrides
  };
}

describe('initialPaletteState', () => {
  it('starts closed, empty, with nothing active', () => {
    expect(initialPaletteState).toEqual({
      open: false,
      query: '',
      results: [],
      skippedNote: null,
      active: -1
    });
  });
});

describe('paletteReduce — open/close', () => {
  it('open resets to an empty query with no results, regardless of prior state', () => {
    const dirty: PaletteState = {
      open: false,
      query: 'stale',
      results: [item()],
      skippedNote: 'Skipped x.',
      active: 0
    };
    const { state, goto } = paletteReduce(dirty, { type: 'open' });
    expect(state).toEqual({ open: true, query: '', results: [], skippedNote: null, active: -1 });
    expect(goto).toBeUndefined();
  });

  it('close resets to the canonical closed state', () => {
    const open: PaletteState = {
      open: true,
      query: 'meeting',
      results: [item()],
      skippedNote: null,
      active: 0
    };
    const { state } = paletteReduce(open, { type: 'close' });
    expect(state).toEqual(initialPaletteState);
  });
});

describe('paletteReduce — input', () => {
  it('sets query/results and selects the first result', () => {
    const results = [item({ path: 'A.md' }), item({ path: 'B.md' })];
    const { state } = paletteReduce(initialPaletteState, { type: 'input', query: 'ab', results });
    expect(state.query).toBe('ab');
    expect(state.results).toEqual(results);
    expect(state.active).toBe(0);
    expect(state.skippedNote).toBeNull();
  });

  it('deselects (active -1) when results are empty', () => {
    const { state } = paletteReduce(initialPaletteState, { type: 'input', query: 'nothing', results: [] });
    expect(state.active).toBe(-1);
  });

  it('carries a skippedNote through when provided', () => {
    const { state } = paletteReduce(initialPaletteState, {
      type: 'input',
      query: 'x',
      results: [item()],
      skippedNote: 'Skipped slow-mount (took too long to search).'
    });
    expect(state.skippedNote).toBe('Skipped slow-mount (took too long to search).');
  });

  it('clears a previous skippedNote when the new input omits it', () => {
    const withNote: PaletteState = { open: true, query: 'x', results: [item()], skippedNote: 'stale', active: 0 };
    const { state } = paletteReduce(withNote, { type: 'input', query: 'y', results: [item()] });
    expect(state.skippedNote).toBeNull();
  });

  it('does not implicitly close the palette', () => {
    const { state } = paletteReduce(initialPaletteState, { type: 'input', query: 'x', results: [] });
    expect(state.open).toBe(false); // input on a closed state stays closed — callers dispatch 'open' first
  });
});

describe('paletteReduce — arrow', () => {
  const withResults: PaletteState = {
    open: true,
    query: 'x',
    results: [item({ path: 'A.md' }), item({ path: 'B.md' }), item({ path: 'C.md' })],
    skippedNote: null,
    active: 0
  };

  it('moves down', () => {
    const { state } = paletteReduce(withResults, { type: 'arrow', direction: 'down' });
    expect(state.active).toBe(1);
  });

  it('moves up', () => {
    const { state } = paletteReduce({ ...withResults, active: 1 }, { type: 'arrow', direction: 'up' });
    expect(state.active).toBe(0);
  });

  it('wraps from the last result to the first going down', () => {
    const { state } = paletteReduce({ ...withResults, active: 2 }, { type: 'arrow', direction: 'down' });
    expect(state.active).toBe(0);
  });

  it('wraps from the first result to the last going up', () => {
    const { state } = paletteReduce({ ...withResults, active: 0 }, { type: 'arrow', direction: 'up' });
    expect(state.active).toBe(2);
  });

  it('is a no-op with no results', () => {
    const empty: PaletteState = { ...initialPaletteState, open: true };
    const { state } = paletteReduce(empty, { type: 'arrow', direction: 'down' });
    expect(state).toEqual(empty);
  });
});

describe('paletteReduce — enter', () => {
  it('returns a /knowledge/<mount>/<encodePath> goto for the active result and closes', () => {
    const state: PaletteState = {
      open: true,
      query: 'tone',
      results: [item({ mount: 'primary', path: 'Guides/Tone & Voice.md' })],
      skippedNote: null,
      active: 0
    };
    const result = paletteReduce(state, { type: 'enter' });
    expect(result.goto).toBe('/knowledge/primary/Guides/Tone%20%26%20Voice.md');
    expect(result.state.open).toBe(false);
  });

  it('is a no-op (no goto, state unchanged) when nothing is active', () => {
    const state: PaletteState = { ...initialPaletteState, open: true };
    const result = paletteReduce(state, { type: 'enter' });
    expect(result.goto).toBeUndefined();
    expect(result.state).toEqual(state);
  });

  it('is a no-op when the active result has no mount (defensive)', () => {
    const state: PaletteState = {
      open: true,
      query: 'tone',
      results: [item({ mount: null })],
      skippedNote: null,
      active: 0
    };
    const result = paletteReduce(state, { type: 'enter' });
    expect(result.goto).toBeUndefined();
    expect(result.state).toEqual(state);
  });
});

describe('highlightSegments', () => {
  it('returns the whole text unbolded when there are no terms', () => {
    expect(highlightSegments('Meeting notes', [])).toEqual([{ text: 'Meeting notes', bold: false }]);
  });

  it('returns the whole text unbolded when no term matches', () => {
    expect(highlightSegments('Meeting notes', ['zzz'])).toEqual([{ text: 'Meeting notes', bold: false }]);
  });

  it('bolds a single case-insensitive substring match', () => {
    expect(highlightSegments('Meeting notes', ['meeting'])).toEqual([
      { text: 'Meeting', bold: true },
      { text: ' notes', bold: false }
    ]);
  });

  it('matches as a substring, not a whole word (mirrors the backend scan)', () => {
    expect(highlightSegments('Meeting notes', ['meet'])).toEqual([
      { text: 'Meet', bold: true },
      { text: 'ing notes', bold: false }
    ]);
  });

  it('bolds multiple distinct non-overlapping matches', () => {
    expect(highlightSegments('Meeting notes', ['meeting', 'notes'])).toEqual([
      { text: 'Meeting', bold: true },
      { text: ' ', bold: false },
      { text: 'notes', bold: true }
    ]);
  });

  it('bolds every occurrence of a repeated term', () => {
    expect(highlightSegments('cat scatter cat', ['cat'])).toEqual([
      { text: 'cat', bold: true },
      { text: ' s', bold: false },
      { text: 'cat', bold: true },
      { text: 'ter ', bold: false },
      { text: 'cat', bold: true }
    ]);
  });

  it('merges overlapping matches from two different terms into one run', () => {
    // "meeting" and "eeting" overlap on the same span.
    expect(highlightSegments('Meeting notes', ['meeting', 'eeting'])).toEqual([
      { text: 'Meeting', bold: true },
      { text: ' notes', bold: false }
    ]);
  });

  it('ignores blank/whitespace-only terms', () => {
    expect(highlightSegments('Meeting notes', ['', '   '])).toEqual([{ text: 'Meeting notes', bold: false }]);
  });
});
