import { describe, it, expect, vi } from 'vitest';
import { createPageLinkSuggestion, buildPageLinkItems } from './page_link_suggestion.js';

// `createPageLinkSuggestion` returns a real `@tiptap/core` `Extension`
// instance. `Extension.create()` synchronously runs `addOptions()` in its
// constructor (see `@tiptap/core`'s `Extension` class) — it doesn't touch
// `this.editor` (that's only read inside `addProseMirrorPlugins`), so
// `.options.suggestion` is inspectable here with no live editor, no DOM,
// and no tippy popup involved.
function makeExtension(overrides = {}) {
  return createPageLinkSuggestion({
    char: '[[',
    name: 'pageLinkBracket',
    mountKey: 'primary',
    pagePath: 'Notes/A.md',
    api: {},
    ...overrides
  });
}

// Fix-wave Finding 1 (task-9.6-report.md "Fix wave" — the "important" one:
// silent link corruption). `api.icmSearch(query, mountKey)` scopes to
// `mountKey` PLUS every ICM it declares related (`Valea.ICM.Search`,
// search.ex:11-14, Task 5.6) — each result row carries its OWN `mount`,
// which need not equal `mountKey`. Before this fix, `toMenuItem`'s command
// handlers called `linkDestination(pagePath, item.path)` for EVERY result,
// ignoring `item.mount` — picking a related-ICM hit computed a relative
// href as if the path lived in the page's own mount, corrupting the link
// (false dangling, or pointing at the wrong file under a different ICM's
// tree). `buildPageLinkItems` is the pure item-shaping step the picker's
// `items()` callback delegates to (factored out for exactly this test, since
// the real `@tiptap/suggestion` `items` callback is buried inside a live
// ProseMirror plugin's view and isn't independently invokable).
function fakeSearchResult(overrides = {}) {
  return {
    path: 'Sibling.md',
    mount: 'primary',
    title: 'Sibling',
    snippet: '',
    terms: [],
    ...overrides
  };
}

describe('buildPageLinkItems', () => {
  it('excludes a related-ICM result whose mount differs from the page being edited', () => {
    const sameMount = fakeSearchResult({ path: 'Sibling.md', mount: 'primary', title: 'Sibling' });
    const otherMount = fakeSearchResult({ path: 'Related.md', mount: 'related-icm', title: 'Related' });

    const items = buildPageLinkItems([sameMount, otherMount], '', {
      pagePath: 'Notes/A.md',
      mountKey: 'primary',
      api: {}
    });

    expect(items.map((item) => item.path)).toEqual(['Sibling.md']);
  });

  it('never lets a cross-mount hit reach a command that could compute a corrupted relative href', () => {
    const otherMount = fakeSearchResult({ path: 'Related.md', mount: 'related-icm', title: 'Related' });

    const items = buildPageLinkItems([otherMount], '', {
      pagePath: 'Notes/A.md',
      mountKey: 'primary',
      api: {}
    });

    expect(items).toEqual([]);
  });

  it('builds a correct same-mount href for a retained result, ignoring the excluded cross-mount hit', () => {
    const sameMount = fakeSearchResult({ path: 'Offers/B.md', mount: 'primary', title: 'B' });
    const otherMount = fakeSearchResult({ path: 'Elsewhere.md', mount: 'related-icm', title: 'Elsewhere' });

    const items = buildPageLinkItems([sameMount, otherMount], '', {
      pagePath: 'Notes/A.md',
      mountKey: 'primary',
      api: {}
    });

    expect(items).toHaveLength(1);

    const deleteRange = vi.fn().mockReturnThis();
    const insertContent = vi.fn().mockReturnThis();
    const run = vi.fn();
    const chain = { focus: vi.fn().mockReturnThis(), deleteRange, insertContent, run };
    chain.deleteRange = vi.fn(() => chain);
    chain.insertContent = vi.fn(() => chain);
    const editor = { chain: vi.fn(() => chain) };

    items[0].command({ editor, range: { from: 0, to: 0 } });

    expect(chain.insertContent).toHaveBeenCalledWith(
      expect.objectContaining({
        marks: [{ type: 'link', attrs: { href: '../Offers/B.md' } }]
      })
    );
  });

  it('keeps every result when all share the page mount (no-op filter)', () => {
    const a = fakeSearchResult({ path: 'A.md', mount: 'primary', title: 'A' });
    const b = fakeSearchResult({ path: 'B.md', mount: 'primary', title: 'B' });

    const items = buildPageLinkItems([a, b], '', { pagePath: 'Notes/A.md', mountKey: 'primary', api: {} });

    expect(items.map((item) => item.path)).toEqual(['A.md', 'B.md']);
  });
});

describe('createPageLinkSuggestion', () => {
  it('sets allowSpaces so a multi-word page title/query survives a space keystroke', () => {
    const extension = makeExtension();

    expect(extension.options.suggestion.allowSpaces).toBe(true);
  });

  it('applies allowSpaces to both the [[ and @ triggers (shared factory)', () => {
    const bracket = makeExtension({ char: '[[', name: 'pageLinkBracket' });
    const mention = makeExtension({ char: '@', name: 'pageLinkMention' });

    expect(bracket.options.suggestion.allowSpaces).toBe(true);
    expect(mention.options.suggestion.allowSpaces).toBe(true);
  });

  it('gives the two same-editor instances distinct pluginKeys (re-pin of the earlier fix)', () => {
    const bracket = makeExtension({ char: '[[', name: 'pageLinkBracket' });
    const mention = makeExtension({ char: '@', name: 'pageLinkMention' });

    expect(bracket.options.suggestion.pluginKey).not.toBe(mention.options.suggestion.pluginKey);
  });
});
