import { describe, expect, it } from 'vitest';
import {
  ORIGIN_LABEL_CAP,
  PANE_CAP,
  chatNavigatorFromUrl,
  dedupeSurfaces,
  paneIdentity,
  panesEqual,
  paneTitle,
  parsePaneParam,
  parsePanes,
  hrefWithPanes,
  paneSearchSuffix,
  promoteTarget,
  serializePaneParam,
  withPanes,
  type ChatNewPaneDescriptor,
  type FilesPaneDescriptor,
  type PaneDescriptor
} from './pane-route';

/** A Files descriptor with the cursor spelled out, so every case reads as one line. */
function files(
  paths: string[],
  active = 0,
  compare: number | null = null,
  mountKey = 'life'
): FilesPaneDescriptor {
  return { kind: 'files', mountKey, paths, active, compare };
}

const filesEmpty = files([]);
const filesOne = files(['AGENTS.md']);
const filesTwo = files(['planning/CONTEXT.md', 'AGENTS.md']);
const chat: PaneDescriptor = { kind: 'chat', sessionId: 'sess-123' };
const chatNew: PaneDescriptor = { kind: 'chat-new', mountKey: 'life', from: null };
const mailList: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: null };
const mailMsg: PaneDescriptor = { kind: 'mail', account: 'mara@example.com', msgId: '8842' };

describe('serialize/parse round-trips', () => {
  it.each([
    filesEmpty,
    filesOne,
    filesTwo,
    files(['a.md', 'b.md', 'c.md'], 2),
    files(['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'], 5),
    files(['a.md', 'b.md'], 0, 1),
    files(['a.md', 'b.md', 'c.md'], 2, 0),
    chat,
    chatNew,
    mailList,
    mailMsg
  ])('%j', (d) => {
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips a literal pipe in a filename without splitting on it', () => {
    const d = files(['a|b.md']);
    expect(serializePaneParam(d)).toContain('%7C');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // The whole reason `@` is safe as the cursor separator: `encodeURIComponent`
  // escapes it, so it can never appear inside an encoded path segment.
  it('round-trips a literal @ in a filename without reading it as a cursor', () => {
    const d = files(['mail@work.md', 'b.md'], 1);
    expect(serializePaneParam(d)).toContain('%40');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips unicode and slashes in file paths', () => {
    const d = files(['ä folder/ünïcode/100%.md'], 0, null, 'm.key');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // The cursor is omitted when it says nothing, so every URL already in the
  // wild keeps its exact current form.
  it('writes no cursor for the default one', () => {
    expect(serializePaneParam(filesOne)).toBe('files:life/AGENTS.md');
    expect(serializePaneParam(files(['a.md', 'b.md']))).toBe('files:life/a.md|b.md');
    expect(serializePaneParam(files(['a.md', 'b.md'], 1))).toBe('files:life/a.md|b.md@1');
    expect(serializePaneParam(files(['a.md', 'b.md'], 1, 0))).toBe('files:life/a.md|b.md@1+0');
  });
});

describe('parsePaneParam — the tab cursor', () => {
  it('defaults the active tab to the first when there is no cursor', () => {
    expect(parsePaneParam('files:life/a.md|b.md')).toEqual(files(['a.md', 'b.md']));
  });

  it('reads the active tab', () => {
    expect(parsePaneParam('files:life/a.md|b.md|c.md@1')).toEqual(
      files(['a.md', 'b.md', 'c.md'], 1)
    );
  });

  it('reads compare as the active tab plus the one beside it', () => {
    expect(parsePaneParam('files:life/a.md|b.md@0+1')).toEqual(files(['a.md', 'b.md'], 0, 1));
  });

  // Clamped rather than refused: the tabs are still perfectly good content,
  // and dropping the pane over a number would cost the user every one of them.
  it('clamps an out-of-range active index to the first tab', () => {
    expect(parsePaneParam('files:life/a.md|b.md@7')).toEqual(files(['a.md', 'b.md']));
  });

  it('drops a compare that cannot be honoured, keeping the tabs', () => {
    // Out of range.
    expect(parsePaneParam('files:life/a.md|b.md@0+9')).toEqual(files(['a.md', 'b.md']));
    // The same tab twice is not a comparison.
    expect(parsePaneParam('files:life/a.md|b.md@1+1')).toEqual(files(['a.md', 'b.md'], 1));
    // Fewer than two tabs.
    expect(parsePaneParam('files:life/a.md@0+1')).toEqual(files(['a.md']));
  });

  // Truncation, not refusal — same posture as the pane cap.
  it('truncates a list longer than the tab cap to the first six', () => {
    expect(parsePaneParam('files:life/a.md|b.md|c.md|d.md|e.md|f.md|g.md|h.md')).toEqual(
      files(['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'])
    );
  });

  it('clamps an active index that the truncation put out of range', () => {
    expect(parsePaneParam('files:life/a.md|b.md|c.md|d.md|e.md|f.md|g.md@6')).toEqual(
      files(['a.md', 'b.md', 'c.md', 'd.md', 'e.md', 'f.md'])
    );
  });
});

describe('parsePaneParam dedupes tabs', () => {
  // `FilesPane` keys its `{#each}` on the path, so a repeated one is a
  // duplicate key — Svelte throws during render and the whole app blanks
  // (no nav, no bar, no error page). Reachable from any hand-written or
  // shared link, so the codec is where it has to stop.
  it('collapses the same file named twice to one tab', () => {
    expect(parsePaneParam('files:life/AGENTS.md|AGENTS.md')).toEqual(files(['AGENTS.md']));
  });

  it('collapses a pair that only matches once decoded', () => {
    expect(parsePaneParam('files:life/planning%2FA.md|planning/A.md')).toEqual(
      files(['planning/A.md'])
    );
  });

  it('leaves two genuinely different files alone', () => {
    expect(parsePaneParam('files:life/A.md|B.md')).toEqual(files(['A.md', 'B.md']));
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
    // A cursor we cannot READ is not a number to guess at — unlike one that is
    // merely out of range, which clamps.
    'files:m/a.md@',
    'files:m/a.md@x',
    'files:m/a.md@1+',
    'files:m/a.md@1+x',
    'files:m/a.md@-1',
    'files:m/a.md@1.5',
    'files:m/a.md@1@2',
    // The cursor without a path list is a descriptor naming nothing.
    'files:m/@1'
  ])('%s -> null', (raw) => {
    expect(parsePaneParam(raw as string | null)).toBeNull();
  });
});

describe('chat-new origin', () => {
  const origin = {
    kind: 'mail-message' as const,
    path: 'views/INBOX/42.md',
    mount: 'mail-mara',
    label: 'Liefertermin'
  };

  it('round-trips a full origin', () => {
    const d: PaneDescriptor = { kind: 'chat-new', mountKey: 'life', from: origin };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  it('round-trips an origin with no mount and no label', () => {
    const d: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'page', path: 'notes/CONTEXT.md' }
    };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // Old links keep working and keep their exact wire form.
  it('leaves the blank composer wire form untouched', () => {
    const d: PaneDescriptor = { kind: 'chat-new', mountKey: 'life', from: null };
    expect(serializePaneParam(d)).toBe('chat:new:life');
    expect(parsePaneParam('chat:new:life')).toEqual(d);
  });

  it('encodes a path so its slashes cannot look like extra fields', () => {
    const d: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'file', path: 'a/b/c.pdf' }
    };
    expect(serializePaneParam(d)).toBe('chat:new:life/file/a%2Fb%2Fc.pdf');
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });

  // A present-but-unreadable origin must NOT degrade to a blank composer:
  // opening detached while looking normal is the bug the descriptor exists
  // to prevent.
  it.each([
    ['chat:new:life/mail-message', 'two fields'],
    ['chat:new:life/nope/x.md', 'unknown kind'],
    ['chat:new:life/page/', 'empty path'],
    ['chat:new:life/page/a/b/c/d', 'too many fields']
  ])('fails closed on a broken origin (%s)', (raw) => {
    expect(parsePaneParam(raw)).toBeNull();
  });

  it('caps a hostile label', () => {
    const long = 'x'.repeat(500);
    const parsed = parsePaneParam(`chat:new:life/page/n.md//${long}`);
    expect(parsed).not.toBeNull();
    expect((parsed as ChatNewPaneDescriptor).from?.label).toHaveLength(ORIGIN_LABEL_CAP);
  });

  // "A different subject still is a different pane" — without this, opening a
  // composer for message A then B recycles the pane and keeps A attached.
  it('gives two origins under one mount distinct identities', () => {
    const a: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'mail-message', path: 'views/INBOX/1.md' }
    };
    const b: PaneDescriptor = {
      kind: 'chat-new',
      mountKey: 'life',
      from: { kind: 'mail-message', path: 'views/INBOX/2.md' }
    };
    expect(paneIdentity(a)).not.toBe(paneIdentity(b));
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
    const other = files(['CONTEXT.md']);
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

describe('hrefWithPanes', () => {
  it('carries the current composition onto a plain href', () => {
    const url = new URL(`https://x/knowledge/life/A.md?pane=${serializePaneParam(chat)}`);
    const out = new URL(hrefWithPanes('/knowledge/life/B.md', url), 'https://x');
    expect(out.pathname).toBe('/knowledge/life/B.md');
    expect(out.searchParams.getAll('pane')).toEqual([serializePaneParam(chat)]);
  });

  it('keeps the params the href itself carries', () => {
    // The rename/delete follow path rebuilds the primary's whole tab strip, so
    // `?tabs=` has to survive the pane re-attachment rather than be replaced.
    const url = new URL(`https://x/knowledge/life/A.md?pane=${serializePaneParam(chat)}`);
    const out = new URL(hrefWithPanes('/knowledge/life/B.md?tabs=B.md|C.md', url), 'https://x');
    expect(out.searchParams.get('tabs')).toBe('B.md|C.md');
    expect(out.searchParams.getAll('pane')).toEqual([serializePaneParam(chat)]);
  });

  it('drops params belonging to the OLD url', () => {
    // `?icm=`/`?session=` mean nothing on the href being navigated to; only
    // the panes travel.
    const url = new URL('https://x/chat?session=a91f&icm=life');
    expect(hrefWithPanes('/knowledge', url)).toBe('/knowledge');
  });

  it('replaces any pane params the href already carried', () => {
    const url = new URL(`https://x/chat?pane=${serializePaneParam(chat)}`);
    const out = new URL(hrefWithPanes('/knowledge?pane=files:stale', url), 'https://x');
    expect(out.searchParams.getAll('pane')).toEqual([serializePaneParam(chat)]);
  });
});

describe('paneSearchSuffix', () => {
  it('is empty for no panes, so a bare href is left alone', () => {
    expect(paneSearchSuffix([])).toBe('');
  });

  it('renders one pane param per descriptor, leading with ?', () => {
    expect(paneSearchSuffix([chat])).toBe(`?pane=${encodeURIComponent(serializePaneParam(chat))}`);
    const both = paneSearchSuffix([chat, filesOne]);
    expect(new URLSearchParams(both.slice(1)).getAll('pane')).toEqual([
      serializePaneParam(chat),
      serializePaneParam(filesOne)
    ]);
  });

  it('enforces the cap, like every other writer', () => {
    expect(new URLSearchParams(paneSearchSuffix([chat, filesOne, mailMsg]).slice(1)).getAll('pane'))
      .toHaveLength(PANE_CAP);
  });
});

describe('dedupeSurfaces', () => {
  it('drops a pane whose kind matches the primary, even with a different subject', () => {
    const primary = files(['README.md']);
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

describe('paneIdentity', () => {
  it('ignores which files a Files pane has open', () => {
    // The defect this exists to prevent: keying a mounted pane on the full
    // wire form made every tree click a remount.
    expect(paneIdentity(filesOne)).toBe(paneIdentity(filesEmpty));
    expect(paneIdentity(filesTwo)).toBe(paneIdentity(filesEmpty));
  });

  it('ignores which message a Mail pane is reading', () => {
    expect(paneIdentity(mailMsg)).toBe(paneIdentity(mailList));
  });

  it('separates a chat-new pane from the session it starts', () => {
    // Load-bearing: ChatView stashes the first prompt at mount, so the started
    // session has to arrive on a fresh component.
    expect(paneIdentity(chatNew)).not.toBe(paneIdentity(chat));
  });

  it('separates two ICMs, two mailboxes and two sessions', () => {
    expect(paneIdentity(filesOne)).not.toBe(
      paneIdentity(files(['AGENTS.md'], 0, null, 'valea'))
    );
    expect(paneIdentity(mailMsg)).not.toBe(
      paneIdentity({ kind: 'mail', account: 'other@example.com', msgId: '8842' })
    );
    expect(paneIdentity(chat)).not.toBe(paneIdentity({ kind: 'chat', sessionId: 'sess-999' }));
  });

  it('separates every kind from every other', () => {
    const ids = [filesOne, chat, chatNew, mailMsg].map(paneIdentity);
    expect(new Set(ids).size).toBe(ids.length);
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
  // The strip names every open file; the header names the one being read.
  it('names the ACTIVE tab, not the first', () => {
    expect(paneTitle(files(['a/one.md', 'b/two.md', 'three.md'], 2))).toBe('three.md');
  });

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
    const otherFiles = files(['B.md']);
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesOne, url, [filesOne, otherFiles]), 'https://x');
    expect(out.searchParams.getAll('pane')).toEqual([]);
  });

  it('carries the whole tab strip onto the route, active tab in the pathname', () => {
    const url = new URL('https://x/chat?session=a91f');
    const out = new URL(promoteTarget(filesTwo, url, [filesTwo]), 'https://x');
    expect(out.pathname).toBe('/knowledge/life/planning/CONTEXT.md');
    expect(out.searchParams.get('tabs')).toBe('planning/CONTEXT.md|AGENTS.md');
  });

  it('promotes onto the tab that was showing, not onto the first one', () => {
    const url = new URL('https://x/chat?session=a91f');
    const pane = files(['a.md', 'b.md', 'c.md'], 2, 0);
    const out = new URL(promoteTarget(pane, url, [pane]), 'https://x');
    expect(out.pathname).toBe('/knowledge/life/c.md');
    expect(out.searchParams.get('tabs')).toBe('a.md|b.md|c.md');
    expect(out.searchParams.get('compare')).toBe('0');
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
