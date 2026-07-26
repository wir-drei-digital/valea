import { describe, expect, it } from 'vitest';
import { lexAgentMarkdown, safeLinkHref, unescapeMarked } from './agent-markdown';

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
