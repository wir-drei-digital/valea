import { describe, it, expect } from 'vitest';
import { createPageLinkSuggestion } from './page_link_suggestion.js';

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
    pagePath: 'Notes/A.md',
    api: {},
    ...overrides
  });
}

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
