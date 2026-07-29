import { describe, expect, it } from 'vitest';
import {
  hrefWithPane,
  paneLinkSearch,
  panesEqual,
  paneTitle,
  parsePaneParam,
  promoteHref,
  serializePaneParam,
  withPaneParam,
  type PaneDescriptor
} from './pane-route';

const file: PaneDescriptor = { kind: 'file', mountKey: 'notes', path: 'projects/valea plan.md' };
const chat: PaneDescriptor = { kind: 'chat', sessionId: 'sess-123' };
const chatNew: PaneDescriptor = { kind: 'chat-new', mountKey: 'notes' };

describe('serialize/parse round-trips', () => {
  it.each([file, chat, chatNew])('%j', (d) => {
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips unicode and slashes in file paths', () => {
    const d: PaneDescriptor = { kind: 'file', mountKey: 'm.key', path: 'ä folder/ünïcode/100%.md' };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });
});

describe('parsePaneParam rejects invalid input', () => {
  it.each([
    null,
    '',
    'file',
    'file:',
    'file:onlymount',
    'file:/no-mount',
    'file:m/',
    'chat:',
    'chat:new:',
    'mail:x',
    ':x',
    'file:m/%E0%A4%A'
  ])('%s -> null', (raw) => {
    expect(parsePaneParam(raw as string | null)).toBeNull();
  });
});

describe('panesEqual', () => {
  it('matches same identity, rejects different', () => {
    expect(panesEqual(file, { ...file })).toBe(true);
    expect(panesEqual(chat, { kind: 'chat', sessionId: 'sess-123' })).toBe(true);
    expect(panesEqual(chat, { kind: 'chat', sessionId: 'other' })).toBe(false);
    expect(panesEqual(file, chat)).toBe(false);
    expect(panesEqual(null, chat)).toBe(false);
    expect(panesEqual(null, null)).toBe(false);
  });
});

describe('withPaneParam', () => {
  it('sets and removes the pane param, preserving other params', () => {
    const url = new URL('http://localhost/chat?session=abc');
    const withPane = withPaneParam(url, chat);
    expect(withPane.startsWith('/chat?')).toBe(true);
    expect(new URLSearchParams(withPane.split('?')[1]).get('session')).toBe('abc');
    expect(parsePaneParam(new URLSearchParams(withPane.split('?')[1]).get('pane'))).toEqual(chat);

    const url2 = new URL(`http://localhost${withPane}`);
    const cleared = withPaneParam(url2, null);
    expect(new URLSearchParams(cleared.split('?')[1] ?? '').get('pane')).toBeNull();
    expect(new URLSearchParams(cleared.split('?')[1] ?? '').get('session')).toBe('abc');
  });
});

describe('paneLinkSearch', () => {
  it('round-trips through a link href, encoding included', () => {
    const url = new URL(`http://localhost/knowledge/notes/a.md?${new URLSearchParams({ pane: serializePaneParam(file) })}`);
    const search = paneLinkSearch(url);
    const linked = new URL(`http://localhost/knowledge/notes/b.md${search}`);
    expect(parsePaneParam(linked.searchParams.get('pane'))).toEqual(file);
  });

  it('is empty for an absent or invalid pane param', () => {
    expect(paneLinkSearch(new URL('http://localhost/knowledge/notes/a.md'))).toBe('');
    expect(paneLinkSearch(new URL('http://localhost/knowledge/notes/a.md?pane=bogus:x'))).toBe('');
  });
});

describe('hrefWithPane', () => {
  it("carries the open pane onto another route's href, keeping that href's own query", () => {
    const url = new URL(`http://localhost/knowledge?icm=notes&${new URLSearchParams({ pane: serializePaneParam(chat) })}`);
    const next = new URL(`http://localhost${hrefWithPane('/knowledge/notes/a.md?raw=1', url)}`);
    expect(next.pathname).toBe('/knowledge/notes/a.md');
    expect(next.searchParams.get('raw')).toBe('1');
    expect(parsePaneParam(next.searchParams.get('pane'))).toEqual(chat);
  });

  it('adds nothing when no valid pane is open', () => {
    expect(hrefWithPane('/knowledge', new URL('http://localhost/knowledge/notes/a.md'))).toBe('/knowledge');
    expect(hrefWithPane('/knowledge', new URL('http://localhost/k?pane=bogus:x'))).toBe('/knowledge');
  });
});

describe('paneTitle / promoteHref', () => {
  it('titles', () => {
    expect(paneTitle(file)).toBe('valea plan.md');
    expect(paneTitle(chat)).toBe('Chat');
    expect(paneTitle(chatNew)).toBe('New session');
  });

  it('promote targets', () => {
    expect(promoteHref(file)).toBe('/knowledge/notes/projects/valea%20plan.md');
    expect(promoteHref(chat)).toBe('/chat?session=sess-123');
    expect(promoteHref(chatNew)).toBe('/chat?icm=notes');
  });
});
