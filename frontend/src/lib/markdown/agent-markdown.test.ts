import { describe, expect, it } from 'vitest';
import {
  codespanFilePath,
  lexAgentMarkdown,
  messageFilePaths,
  safeLinkHref,
  unescapeMarked
} from './agent-markdown';

describe('lexAgentMarkdown', () => {
  it('lexes the block shapes the renderer dispatches on', () => {
    const tokens = lexAgentMarkdown(
      '## Maildir\n\nSome **bold** and `code`.\n\n- one\n- two\n\n```sh\nls cur/\n```\n\n> quoted'
    );
    const types = tokens.map((t) => t.type);
    expect(types).toContain('heading');
    expect(types).toContain('paragraph');
    expect(types).toContain('list');
    expect(types).toContain('code');
    expect(types).toContain('blockquote');

    const heading = tokens.find((t) => t.type === 'heading') as { depth: number };
    expect(heading.depth).toBe(2);

    const list = tokens.find((t) => t.type === 'list') as { items: unknown[] };
    expect(list.items).toHaveLength(2);
  });

  it('treats a single newline as a break (chat-style lines)', () => {
    const tokens = lexAgentMarkdown('line one\nline two');
    const paragraph = tokens.find((t) => t.type === 'paragraph') as { tokens: Array<{ type: string }> };
    expect(paragraph.tokens.some((t) => t.type === 'br')).toBe(true);
  });

  it('keeps raw HTML as an html token (rendered as text downstream, never markup)', () => {
    const tokens = lexAgentMarkdown('before <script>alert(1)</script> after');
    const paragraph = tokens.find((t) => t.type === 'paragraph') as { tokens: Array<{ type: string }> };
    expect(paragraph.tokens.some((t) => t.type === 'html')).toBe(true);
  });
});

describe('safeLinkHref', () => {
  it('allows http(s) and mailto', () => {
    expect(safeLinkHref('https://example.com/a?b=c')).toBe('https://example.com/a?b=c');
    expect(safeLinkHref('http://localhost:4200')).toBe('http://localhost:4200');
    expect(safeLinkHref('mailto:mara@example.com')).toBe('mailto:mara@example.com');
  });

  it('rejects every other scheme and empty values', () => {
    expect(safeLinkHref('javascript:alert(1)')).toBeNull();
    expect(safeLinkHref('data:text/html,x')).toBeNull();
    expect(safeLinkHref('file:///etc/passwd')).toBeNull();
    expect(safeLinkHref('relative/path.md')).toBeNull();
    expect(safeLinkHref('')).toBeNull();
    expect(safeLinkHref(null)).toBeNull();
  });
});

describe('unescapeMarked', () => {
  it('reverses exactly the entities marked pre-escapes, so codespans render literally', () => {
    expect(unescapeMarked('&lt;div class=&quot;x&quot;&gt; &amp; &#39;y&#39;')).toBe(
      '<div class="x"> & \'y\''
    );
  });

  it('codespan token text round-trips to the literal source', () => {
    const tokens = lexAgentMarkdown('use `<div>` here');
    const paragraph = tokens.find((t) => t.type === 'paragraph') as {
      tokens: Array<{ type: string; text?: string }>;
    };
    const codespan = paragraph.tokens.find((t) => t.type === 'codespan');
    expect(unescapeMarked(codespan?.text ?? '')).toBe('<div>');
  });
});

describe('codespanFilePath', () => {
  it('accepts relative paths with an extension, stripping one :line suffix', () => {
    expect(codespanFilePath('CONTEXT.md')).toBe('CONTEXT.md');
    expect(codespanFilePath('CONTEXT.md:22')).toBe('CONTEXT.md');
    expect(codespanFilePath('notes/a.md')).toBe('notes/a.md');
    expect(codespanFilePath('clients/Mara Lindt/notes.md')).toBe('clients/Mara Lindt/notes.md');
    expect(codespanFilePath('today.json')).toBe('today.json');
  });

  it('rejects non-path shapes', () => {
    expect(codespanFilePath('')).toBeUndefined();
    expect(codespanFilePath('README')).toBeUndefined(); // no extension
    expect(codespanFilePath('v1.2')).toBeUndefined(); // digit "extension"
    expect(codespanFilePath('.md')).toBeUndefined(); // extension only, no stem
    expect(codespanFilePath('e.g.')).toBeUndefined(); // trailing dot
    expect(codespanFilePath('foo bar.md')).toBeUndefined(); // space without slash
    expect(codespanFilePath('call(x).md')).toBeUndefined(); // parens
    expect(codespanFilePath('a\tb/c.md')).toBeUndefined(); // tab
    expect(codespanFilePath('a\nb/c.md')).toBeUndefined(); // newline
    expect(codespanFilePath(`${'x'.repeat(300)}.md`)).toBeUndefined(); // length cap
  });

  it('rejects absolute, traversal, directory, and scheme-ish strings', () => {
    expect(codespanFilePath('/abs/x.md')).toBeUndefined();
    expect(codespanFilePath('~/x.md')).toBeUndefined();
    expect(codespanFilePath('../x.md')).toBeUndefined();
    expect(codespanFilePath('a/../b.md')).toBeUndefined();
    expect(codespanFilePath('a//b.md')).toBeUndefined();
    expect(codespanFilePath('notes/')).toBeUndefined();
    expect(codespanFilePath('https://example.com/a.md')).toBeUndefined();
    expect(codespanFilePath('mailto:mara@example.com')).toBeUndefined();
    expect(codespanFilePath('CONTEXT.md:22:7')).toBeUndefined(); // only ONE :NN suffix
  });
});

describe('messageFilePaths', () => {
  it('collects distinct codespan paths across inline structures', () => {
    const text =
      'See `CONTEXT.md` and again `CONTEXT.md:1`, plus **bold `notes/a.md`**\n\n' +
      '- item with `clients/x.md`\n\n' +
      '| h |\n| - |\n| `cell.md` |';
    expect(messageFilePaths(text)).toEqual(['CONTEXT.md', 'notes/a.md', 'clients/x.md', 'cell.md']);
  });

  it('ignores fenced code blocks, plain text, and URL codespans', () => {
    expect(messageFilePaths('```\ninside.md\n```\nplain CONTEXT.md text')).toEqual([]);
    expect(messageFilePaths('at `https://example.com/a.md` only')).toEqual([]);
  });

  it('runs detection on DECODED codespan text', () => {
    // marked pre-escapes `&` in codespan token text; the path must come back decoded.
    expect(messageFilePaths('see `a&b.md`')).toEqual(['a&b.md']);
  });

  it('returns [] for empty input', () => {
    expect(messageFilePaths('')).toEqual([]);
  });
});
