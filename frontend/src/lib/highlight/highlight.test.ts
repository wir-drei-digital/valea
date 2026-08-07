import { describe, it, expect } from 'vitest';
import type { Element, RootContent } from 'hast';
import { GRAMMARS } from './languages';
import { highlight, MAX_HIGHLIGHT_CHARS } from './highlight';

/** Every `hljs-…` class anywhere in the tree, flattened. */
function classes(nodes: RootContent[]): string[] {
  return nodes.flatMap((node) => {
    if (node.type !== 'element') return [];
    const element = node as Element;
    const own = element.properties?.className;
    const mine = Array.isArray(own) ? own.map(String) : [];
    return [...mine, ...classes(element.children as RootContent[])];
  });
}

function flatten(nodes: RootContent[]): string {
  return nodes
    .map((n) =>
      n.type === 'text' ? n.value : n.type === 'element' ? flatten(n.children as RootContent[]) : ''
    )
    .join('');
}

describe('highlight', () => {
  it('returns a hast tree carrying hljs classes', async () => {
    const tree = await highlight('defmodule Foo do\nend\n', 'elixir');
    expect(tree).not.toBeNull();
    expect(classes(tree!.children as RootContent[])).toContain('hljs-keyword');
  });

  it('preserves the source text exactly', async () => {
    const code = 'const x = "hi";\n\nconst y = 2;\n';
    const tree = await highlight(code, 'typescript');
    expect(flatten(tree!.children as RootContent[])).toBe(code);
  });

  it('returns null for no grammar', async () => {
    expect(await highlight('plain text', null)).toBeNull();
  });

  it('returns null above the size cap rather than tokenising it', async () => {
    const huge = 'x'.repeat(MAX_HIGHLIGHT_CHARS + 1);
    expect(await highlight(huge, 'typescript')).toBeNull();
  });

  it('loads every grammar the language map can return', async () => {
    for (const grammar of GRAMMARS) {
      expect(await highlight('a', grammar), grammar).not.toBeNull();
    }
  });
});
