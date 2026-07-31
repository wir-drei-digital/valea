import { describe, expect, it } from 'vitest';
import {
  PANE_CAP,
  chatNavigatorFromUrl,
  dedupeSurfaces,
  hrefWithPane,
  paneLinkSearch,
  panesEqual,
  paneTitle,
  parsePaneParam,
  parsePanes,
  promoteHref,
  serializePaneParam,
  withPaneParam,
  withPanes,
  type PaneDescriptor
} from './pane-route';

const filesEmpty: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [] };
const filesOne: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['AGENTS.md'] };
const filesTwo: PaneDescriptor = {
  kind: 'files',
  mountKey: 'life',
  paths: ['planning/CONTEXT.md', 'AGENTS.md']
};
const chat: PaneDescriptor = { kind: 'chat', sessionId: 'sess-123' };
const chatNew: PaneDescriptor = { kind: 'chat-new', mountKey: 'life' };
const mailList: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: null };
const mailMsg: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: '8842' };

describe('serialize/parse round-trips', () => {
  it.each([filesEmpty, filesOne, filesTwo, chat, chatNew, mailList, mailMsg])('%j', (d) => {
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips a literal pipe in a filename without splitting on it', () => {
    const d: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['a|b.md'] };
    expect(serializePaneParam(d)).toContain('%7C');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips unicode and slashes in file paths', () => {
    const d: PaneDescriptor = {
      kind: 'files',
      mountKey: 'm.key',
      paths: ['ä folder/ünïcode/100%.md']
    };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });
});

describe('parsePaneParam fails closed', () => {
  it.each([
    null,
    '',
    'files',
    'files:',
    'files:/no-mount',
    'files:m/',
    'files:m/a||b',
    'chat:',
    'chat:new:',
    'mail:',
    'mail:/8842',
    ':x',
    'files:m/%E0%A4%A',
    'files:m/a|b|c'
  ])('%s -> null', (raw) => {
    expect(parsePaneParam(raw as string | null)).toBeNull();
  });
});

describe('parsePanes', () => {
  function params(...panes: string[]): URLSearchParams {
    const p = new URLSearchParams();
    for (const v of panes) p.append('pane', v);
    return p;
  }

  it('reads a single ?pane= as a one-element list (back-compat)', () => {
    expect(parsePanes(params(serializePaneParam(chat)))).toEqual([chat]);
  });

  it('preserves document order', () => {
    const got = parsePanes(params(serializePaneParam(filesOne), serializePaneParam(chat)));
    expect(got).toEqual([filesOne, chat]);
  });

  it('drops panes beyond the cap', () => {
    const got = parsePanes(
      params(serializePaneParam(filesOne), serializePaneParam(chat), serializePaneParam(mailList))
    );
    expect(got).toHaveLength(PANE_CAP);
    expect(got).toEqual([filesOne, chat]);
  });

  it('drops invalid entries without discarding the valid ones', () => {
    expect(parsePanes(params('garbage', serializePaneParam(chat)))).toEqual([chat]);
  });

  it('returns an empty list when there are no pane params', () => {
    expect(parsePanes(new URLSearchParams())).toEqual([]);
  });

  it('collapses two panes of the same kind', () => {
    const other: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['CONTEXT.md'] };
    expect(parsePanes(params(serializePaneParam(filesOne), serializePaneParam(other)))).toEqual([
      filesOne
    ]);
  });
});

describe('withPanes', () => {
  it('writes one pane param per descriptor and preserves other params', () => {
    const url = new URL('https://x/chat?session=a91f&icm=life');
    const href = withPanes(url, [filesOne, chat]);
    const out = new URL(href, 'https://x');
    expect(out.searchParams.get('session')).toBe('a91f');
    expect(out.searchParams.get('icm')).toBe('life');
    expect(out.searchParams.getAll('pane')).toEqual([
      serializePaneParam(filesOne),
      serializePaneParam(chat)
    ]);
  });

  it('removes every pane param when given an empty list', () => {
    const url = new URL('https://x/chat?session=a91f&pane=chat:z&pane=files:life');
    expect(new URL(withPanes(url, []), 'https://x').searchParams.getAll('pane')).toEqual([]);
  });
});

describe('dedupeSurfaces', () => {
  it('drops a pane whose kind matches the primary, even with a different subject', () => {
    const primary: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['README.md'] };
    expect(dedupeSurfaces(primary, [filesOne, chat])).toEqual([chat]);
  });

  it('drops a Files pane on a route with a null primary descriptor', () => {
    expect(dedupeSurfaces(null, [filesOne, filesTwo])).toEqual([filesOne]);
  });

  it('allows chat-new beside chat', () => {
    expect(dedupeSurfaces(chat, [chatNew])).toEqual([chatNew]);
  });

  it('keeps distinct kinds', () => {
    expect(dedupeSurfaces(chat, [filesOne, mailList])).toEqual([filesOne, mailList]);
  });
});

describe('panesEqual', () => {
  it('is identity, not kind', () => {
    expect(panesEqual(filesOne, filesOne)).toBe(true);
    expect(panesEqual(filesOne, filesTwo)).toBe(false);
    expect(panesEqual(null, null)).toBe(false);
  });
});

describe('chatNavigatorFromUrl', () => {
  it('reads the legacy ?all=1 alias', () => {
    expect(chatNavigatorFromUrl(new URL('https://x/chat?all=1'))).toBe(true);
    expect(chatNavigatorFromUrl(new URL('https://x/chat'))).toBe(false);
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
    const url = new URL(
      `http://localhost/knowledge/life/a.md?${new URLSearchParams({ pane: serializePaneParam(filesTwo) })}`
    );
    const search = paneLinkSearch(url);
    const linked = new URL(`http://localhost/knowledge/life/b.md${search}`);
    expect(parsePaneParam(linked.searchParams.get('pane'))).toEqual(filesTwo);
  });

  it('is empty for an absent or invalid pane param', () => {
    expect(paneLinkSearch(new URL('http://localhost/knowledge/notes/a.md'))).toBe('');
    expect(paneLinkSearch(new URL('http://localhost/knowledge/notes/a.md?pane=bogus:x'))).toBe('');
  });
});

describe('hrefWithPane', () => {
  it("carries the open pane onto another route's href, keeping that href's own query", () => {
    const url = new URL(
      `http://localhost/knowledge?icm=notes&${new URLSearchParams({ pane: serializePaneParam(chat) })}`
    );
    const next = new URL(`http://localhost${hrefWithPane('/knowledge/notes/a.md?raw=1', url)}`);
    expect(next.pathname).toBe('/knowledge/notes/a.md');
    expect(next.searchParams.get('raw')).toBe('1');
    expect(parsePaneParam(next.searchParams.get('pane'))).toEqual(chat);
  });

  it('adds nothing when no valid pane is open', () => {
    expect(hrefWithPane('/knowledge', new URL('http://localhost/knowledge/notes/a.md'))).toBe(
      '/knowledge'
    );
    expect(hrefWithPane('/knowledge', new URL('http://localhost/k?pane=bogus:x'))).toBe(
      '/knowledge'
    );
  });
});

describe('paneTitle / promoteHref', () => {
  it('titles', () => {
    expect(paneTitle(filesEmpty)).toBe('Files');
    expect(paneTitle(filesTwo)).toBe('CONTEXT.md');
    expect(paneTitle(chat)).toBe('Chat');
    expect(paneTitle(chatNew)).toBe('New session');
    expect(paneTitle(mailList)).toBe('Mail');
  });

  it('promote targets', () => {
    expect(promoteHref(filesTwo)).toBe('/knowledge/life/planning/CONTEXT.md');
    expect(promoteHref(filesEmpty)).toBe('/knowledge?icm=life');
    expect(promoteHref(chat)).toBe('/chat?session=sess-123');
    expect(promoteHref(chatNew)).toBe('/chat?icm=life');
    expect(promoteHref(mailMsg)).toBe('/mail?account=mara%40example.com&message=8842');
  });
});
