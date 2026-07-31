import { describe, expect, it } from 'vitest';
import {
  PANE_CAP,
  chatNavigatorFromUrl,
  dedupeSurfaces,
  panesEqual,
  paneTitle,
  parsePaneParam,
  parsePanes,
  promoteTarget,
  serializePaneParam,
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

  // `promoteTarget` filters a descriptor parsed from one place against a list
  // parsed from another, so same-content/different-object MUST compare equal.
  it('is structural, not reference identity', () => {
    expect(panesEqual(filesOne, { ...filesOne, paths: [...filesOne.paths] })).toBe(true);
    expect(panesEqual(chat, { kind: 'chat', sessionId: 'sess-123' })).toBe(true);
    expect(panesEqual(chat, { kind: 'chat', sessionId: 'other' })).toBe(false);
    expect(panesEqual(mailList, { kind: 'mail', account: 'mara@example.com', msgId: null })).toBe(
      true
    );
    expect(panesEqual(mailList, mailMsg)).toBe(false);
    expect(panesEqual(filesOne, chat)).toBe(false);
  });

  it('is false when either side is null', () => {
    expect(panesEqual(null, chat)).toBe(false);
    expect(panesEqual(chat, null)).toBe(false);
    expect(panesEqual(null, null)).toBe(false);
  });
});

describe('chatNavigatorFromUrl', () => {
  it('reads the legacy ?all=1 alias', () => {
    expect(chatNavigatorFromUrl(new URL('https://x/chat?all=1'))).toBe(true);
    expect(chatNavigatorFromUrl(new URL('https://x/chat'))).toBe(false);
  });
});

describe('paneTitle', () => {
  it('titles', () => {
    expect(paneTitle(filesEmpty)).toBe('Files');
    expect(paneTitle(filesTwo)).toBe('CONTEXT.md');
    expect(paneTitle(chat)).toBe('Chat');
    expect(paneTitle(chatNew)).toBe('New session');
    expect(paneTitle(mailList)).toBe('Mail');
  });
});

describe('promoteTarget', () => {
  it('promotes a chat pane and keeps the other pane', () => {
    const url = new URL('https://x/knowledge/life/AGENTS.md?pane=chat:s1&pane=mail:a%40b.com');
    const href = promoteTarget(chat, url, [chat, mailList]);
    const out = new URL(href, 'https://x');
    expect(out.pathname).toBe('/chat');
    expect(out.searchParams.get('session')).toBe('sess-123');
    expect(out.searchParams.getAll('pane')).toEqual([serializePaneParam(mailList)]);
  });

  it('drops the promoted pane from the surviving list', () => {
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesOne, url, [filesOne]), 'https://x');
    expect(out.searchParams.getAll('pane')).toEqual([]);
  });

  it('suppresses a surviving pane whose kind matches the new primary', () => {
    const otherFiles: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['B.md'] };
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesOne, url, [filesOne, otherFiles]), 'https://x');
    expect(out.searchParams.getAll('pane')).toEqual([]);
  });

  it('carries both Files splits onto the route via ?split=', () => {
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesTwo, url, [filesTwo]), 'https://x');
    expect(out.pathname).toBe('/knowledge/life/planning/CONTEXT.md');
    expect(out.searchParams.get('split')).toBe('AGENTS.md');
  });

  it('promotes a Files pane with no file to the mount index', () => {
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesEmpty, url, [filesEmpty]), 'https://x');
    expect(out.pathname).toBe('/knowledge');
    expect(out.searchParams.get('icm')).toBe('life');
  });

  it('carries account and message for mail', () => {
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(mailMsg, url, [mailMsg]), 'https://x');
    expect(out.pathname).toBe('/mail');
    expect(out.searchParams.get('account')).toBe('mara@example.com');
    expect(out.searchParams.get('message')).toBe('8842');
  });

  it('does not carry the old primary’s params across a kind change', () => {
    const url = new URL('https://x/chat?session=a91f&all=1&icm=life&drafts=1');
    const out = new URL(promoteTarget(mailList, url, [mailList]), 'https://x');
    expect(out.searchParams.get('session')).toBeNull();
    expect(out.searchParams.get('all')).toBeNull();
    expect(out.searchParams.get('icm')).toBeNull();
    expect(out.searchParams.get('drafts')).toBeNull();
  });
});
