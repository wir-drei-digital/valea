import { describe, expect, it } from 'vitest';
import { filesPrimaryHref, parseFilesPrimary } from './files-url';
import type { TabState } from './files-pane-state';

function tabs(paths: string[], active = 0, compare: number | null = null): TabState {
  return { paths, active, compare };
}

/** The query half of a primary Files URL, as the route reads it. */
function query(search: string): URLSearchParams {
  return new URL(`https://x/knowledge/life/a.md${search}`).searchParams;
}

describe('parseFilesPrimary', () => {
  it('reads a bare file route as one tab', () => {
    expect(parseFilesPrimary('a.md', query(''))).toEqual(tabs(['a.md']));
  });

  it('reads the strip, with the pathname as the active tab', () => {
    expect(parseFilesPrimary('b.md', query('?tabs=a.md|b.md|c.md'))).toEqual(
      tabs(['a.md', 'b.md', 'c.md'], 1)
    );
  });

  it('reads compare', () => {
    expect(parseFilesPrimary('b.md', query('?tabs=a.md|b.md&compare=0'))).toEqual(
      tabs(['a.md', 'b.md'], 1, 0)
    );
  });

  // A folder route has no open file, so it has no strip either.
  it('has no tabs on a folder route', () => {
    expect(parseFilesPrimary('', query('?tabs=a.md|b.md'))).toEqual(tabs([]));
  });

  // The pathname is the route: it always renders, whatever the query claims.
  it('prepends a pathname the strip does not list', () => {
    expect(parseFilesPrimary('z.md', query('?tabs=a.md|b.md'))).toEqual(
      tabs(['z.md', 'a.md', 'b.md'], 0)
    );
  });

  it('dedupes, truncates and clamps like the wire form does', () => {
    expect(parseFilesPrimary('a.md', query('?tabs=a.md|b.md|a.md')).paths).toEqual([
      'a.md',
      'b.md'
    ]);
    expect(
      parseFilesPrimary('a.md', query('?tabs=a.md|b.md|c.md|d.md|e.md|f.md|g.md')).paths
    ).toHaveLength(6);
    expect(parseFilesPrimary('a.md', query('?tabs=a.md|b.md&compare=9')).compare).toBeNull();
    expect(parseFilesPrimary('a.md', query('?tabs=a.md|b.md&compare=x')).compare).toBeNull();
  });

  it('decodes path segments, so a slash in the query is not a separator', () => {
    expect(
      parseFilesPrimary('planning/CONTEXT.md', query('?tabs=a.md|planning/CONTEXT.md')).paths
    ).toEqual(['a.md', 'planning/CONTEXT.md']);
    // A per-segment escape is undone once, not twice: `%2525` in the address
    // is one literal percent sign in the filename.
    expect(parseFilesPrimary('a.md', query('?tabs=a.md|100%2525.md')).paths).toEqual([
      'a.md',
      '100%.md'
    ]);
  });
});

describe('filesPrimaryHref', () => {
  it('is the mount root when nothing is open', () => {
    expect(filesPrimaryHref('life', tabs([]))).toBe('/knowledge/life');
  });

  // One tab is exactly the URL this route has always had — no strip param at
  // all, so the common address stays as short as it was.
  it('is a bare file route for one tab', () => {
    expect(filesPrimaryHref('life', tabs(['planning/CONTEXT.md']))).toBe(
      '/knowledge/life/planning/CONTEXT.md'
    );
  });

  it('puts the active tab in the pathname and the strip in ?tabs=', () => {
    const url = new URL(filesPrimaryHref('life', tabs(['a.md', 'b.md', 'c.md'], 2)), 'https://x');
    expect(url.pathname).toBe('/knowledge/life/c.md');
    expect(url.searchParams.get('tabs')).toBe('a.md|b.md|c.md');
  });

  it('writes compare as an index', () => {
    const url = new URL(filesPrimaryHref('life', tabs(['a.md', 'b.md'], 1, 0)), 'https://x');
    expect(url.pathname).toBe('/knowledge/life/b.md');
    expect(url.searchParams.get('compare')).toBe('0');
  });

  // The escape that a single encoding layer loses: the query decoder would
  // turn the `%7C` guarding a literal pipe back into a separator, and one tab
  // would read back as two.
  it('keeps a literal pipe in a filename out of the separator’s way', () => {
    const url = new URL(filesPrimaryHref('life', tabs(['a|b.md', 'c.md'])), 'https://x');
    expect(url.searchParams.get('tabs')).toBe('a%7Cb.md|c.md');
  });

  it('round-trips through the route’s own reader', () => {
    for (const state of [
      tabs(['a.md']),
      tabs(['a.md', 'b.md'], 1),
      tabs(['a.md', 'planning/b.md', 'c.md'], 2, 0),
      tabs(['ä/ünï.md', 'a|b.md', 'mail@work.md'], 1)
    ]) {
      const url = new URL(filesPrimaryHref('life', state), 'https://x');
      const path = url.pathname
        .slice('/knowledge/life/'.length)
        .split('/')
        .map(decodeURIComponent)
        .join('/');
      expect(parseFilesPrimary(path, url.searchParams)).toEqual(state);
    }
  });
});
