import { describe, it, expect } from 'vitest';
import { classifyHref, collectDocLinkPaths } from './link-nav';

describe('classifyHref', () => {
  it('resolves a relative .md href against the linking page (workspace-relative)', () => {
    expect(classifyHref('../Offers/X.md', 'Notes/A.md')).toEqual({ kind: 'page', path: 'Offers/X.md' });
  });

  it('resolves a same-directory relative .md href', () => {
    expect(classifyHref('Sibling.md', 'Notes/A.md')).toEqual({ kind: 'page', path: 'Notes/Sibling.md' });
  });

  // Fix-wave Finding 2 (task-9.6-report.md): post-Phase-4, every in-ICM path
  // is ICM-relative — mount identity rides `mountKey`, a value passed
  // alongside the path, never a leading `/` on the path string itself (see
  // `image-upload.ts`'s `resolveImageSrc`/`joinRelative`, already updated
  // for this Task 9.6 vocabulary). A leading-slash `.md` href in
  // hand-authored content is read as ICM-ROOT-relative, not as an
  // "absolute physical path ⇒ external mount" tag — that vocabulary no
  // longer exists. Before this fix, the href passed through verbatim (with
  // its leading slash intact) and `PageEditor.svelte`'s click handler built
  // `/knowledge/<mountKey>//Offers/B.md` (an empty path segment before
  // "Offers") — the `[...path]` route then silently landed on the empty
  // Knowledge root instead of the linked page.
  it('treats a leading-slash .md href as ICM-root-relative (post-Phase-4 vocabulary, not external-mount-absolute)', () => {
    expect(classifyHref('/Offers/B.md', 'Notes/A.md')).toEqual({ kind: 'page', path: 'Offers/B.md' });
  });

  it('strips multiple leading slashes on a root-relative href the same way', () => {
    expect(classifyHref('//Offers/B.md', 'Notes/A.md')).toEqual({ kind: 'page', path: 'Offers/B.md' });
  });

  it('resolves a root-relative href the same regardless of the linking page location', () => {
    expect(classifyHref('/Offers/B.md', 'Deeply/Nested/Notes/A.md')).toEqual({
      kind: 'page',
      path: 'Offers/B.md'
    });
  });

  it('is case-insensitive on the .md extension', () => {
    expect(classifyHref('Sibling.MD', 'Notes/A.md')).toEqual({ kind: 'page', path: 'Notes/Sibling.MD' });
  });

  it('classifies an http href as external', () => {
    expect(classifyHref('http://example.com/x', 'Notes/A.md')).toEqual({
      kind: 'external',
      url: 'http://example.com/x'
    });
  });

  it('classifies an https href as external', () => {
    expect(classifyHref('https://example.com/x', 'Notes/A.md')).toEqual({
      kind: 'external',
      url: 'https://example.com/x'
    });
  });

  it('classifies anything else (non-.md file, mailto:, etc.) as file', () => {
    expect(classifyHref('../Assets/photo.png', 'Notes/A.md')).toEqual({ kind: 'file' });
    expect(classifyHref('mailto:a@example.com', 'Notes/A.md')).toEqual({ kind: 'file' });
  });
});

describe('collectDocLinkPaths', () => {
  function doc(content: unknown[]): Record<string, unknown> {
    return { type: 'doc', content };
  }

  function textWithLink(text: string, href: string): Record<string, unknown> {
    return { type: 'text', text, marks: [{ type: 'link', attrs: { href } }] };
  }

  it('collects a resolved relative link mark path', () => {
    const d = doc([{ type: 'paragraph', content: [textWithLink('sibling', 'Sibling.md')] }]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual(['Notes/Sibling.md']);
  });

  it('collects a leading-slash link mark path as ICM-root-relative (Fix-wave Finding 2)', () => {
    const d = doc([{ type: 'paragraph', content: [textWithLink('ext', '/Offers/B.md')] }]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual(['Offers/B.md']);
  });

  it('excludes an http(s) link — not a page-kind href', () => {
    const d = doc([{ type: 'paragraph', content: [textWithLink('site', 'https://example.com')] }]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual([]);
  });

  it('excludes an image node (non-.md src is file-kind, not page-kind)', () => {
    const d = doc([
      { type: 'paragraph', content: [{ type: 'image', attrs: { src: '../Assets/photo.png' } }] }
    ]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual([]);
  });

  it('walks nested content (lists, blockquotes) for link marks', () => {
    const d = doc([
      {
        type: 'bulletList',
        content: [
          {
            type: 'listItem',
            content: [{ type: 'paragraph', content: [textWithLink('nested', 'Nested.md')] }]
          }
        ]
      }
    ]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual(['Notes/Nested.md']);
  });

  it('dedupes repeated links to the same resolved path', () => {
    const d = doc([
      {
        type: 'paragraph',
        content: [textWithLink('one', 'Sibling.md'), textWithLink('two', 'Sibling.md')]
      }
    ]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual(['Notes/Sibling.md']);
  });

  it('returns an empty array for a doc with no links or images', () => {
    const d = doc([{ type: 'paragraph', content: [{ type: 'text', text: 'plain text' }] }]);
    expect(collectDocLinkPaths(d, 'Notes/A.md')).toEqual([]);
  });

  it('tolerates a malformed/empty doc without throwing', () => {
    expect(collectDocLinkPaths({}, 'Notes/A.md')).toEqual([]);
    expect(collectDocLinkPaths({ type: 'doc' }, 'Notes/A.md')).toEqual([]);
  });
});
