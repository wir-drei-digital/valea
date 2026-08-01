import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import {
  loadChrome,
  loadNavVisible,
  loadPanes,
  restoreTarget,
  routeKeyFor,
  savePanes,
  saveChrome,
  saveNavVisible
} from './pane-memory';
import { serializePaneParam, type PaneDescriptor } from './pane-route';

// This vitest setup runs on the default (node) environment, where the
// `localStorage` global is not a usable Web Storage object — the same
// in-memory stubbing pattern as `pane-split.test.ts` applies here.
function installFakeLocalStorage(): void {
  const data = new Map<string, string>();
  const fake = {
    getItem: (key: string) => (data.has(key) ? data.get(key)! : null),
    setItem: (key: string, value: string) => {
      data.set(key, value);
    },
    removeItem: (key: string) => {
      data.delete(key);
    },
    clear: () => data.clear()
  };
  Object.defineProperty(globalThis, 'localStorage', { value: fake, configurable: true, writable: true });
}

function removeLocalStorage(): void {
  // @ts-expect-error - deliberately deleting the global for the guard test
  delete globalThis.localStorage;
}

const chat: PaneDescriptor = { kind: 'chat', sessionId: 's1' };
const files: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['A.md'] };

describe('restoreTarget', () => {
  const mail: PaneDescriptor = { kind: 'mail', account: 'a@b.c', msgId: null };
  // nav 236 + primary 380 = 616 before the first 300px pane, so 1600px has
  // room for two, 1000px for one and 900px for none.
  const base = {
    urlNamesPanes: false,
    remembered: [chat, mail],
    primary: null as PaneDescriptor | null,
    windowWidth: 1600 as number | undefined,
    navVisible: true
  };

  it('restores the remembered row when the URL names no panes', () => {
    expect(restoreTarget(base)).toEqual([chat, mail]);
  });

  it('refuses to restore anything when the URL names a pane', () => {
    // The whole point: a link shared between two people is never rewritten by
    // the recipient's habits.
    expect(restoreTarget({ ...base, urlNamesPanes: true })).toBeNull();
  });

  it('truncates to what fits, and keeps the row it was given intact', () => {
    const remembered = [chat, mail];
    expect(restoreTarget({ ...base, remembered, windowWidth: 1000 })).toEqual([chat]);
    expect(remembered).toEqual([chat, mail]);
  });

  it('restores nothing when not even one pane fits', () => {
    expect(restoreTarget({ ...base, windowWidth: 900 })).toBeNull();
  });

  it('counts the width the hidden nav gives back', () => {
    expect(restoreTarget({ ...base, windowWidth: 1000, navVisible: false })).toEqual([chat, mail]);
  });

  it('restores nothing when the window has not been measured', () => {
    // Pins the OUTCOME, not the guard: `panesThatFit(NaN, …)` returns NaN and
    // `slice(0, NaN)` happens to give an empty row, so removing the explicit
    // `Number.isFinite` check leaves this green. The check is kept anyway —
    // the same discipline `AppShell` applies at its own call site — because
    // relying on `slice`'s leniency is not a thing to inherit.
    expect(restoreTarget({ ...base, windowWidth: undefined })).toBeNull();
    expect(restoreTarget({ ...base, windowWidth: Number.NaN })).toBeNull();
  });

  it('drops a remembered pane that duplicates the route primary', () => {
    expect(restoreTarget({ ...base, primary: { kind: 'chat', sessionId: 'other' } })).toEqual([
      mail
    ]);
  });

  it('dedupes BEFORE truncating, so a surviving pane is not lost to the cut', () => {
    // Truncating first gives [chat], which dedup then removes — restoring
    // nothing, when the mail pane both fitted and belonged.
    expect(
      restoreTarget({
        ...base,
        primary: { kind: 'chat', sessionId: 'other' },
        windowWidth: 1000
      })
    ).toEqual([mail]);
  });

  it('restores nothing when nothing is remembered', () => {
    expect(restoreTarget({ ...base, remembered: [] })).toBeNull();
  });
});

describe('routeKeyFor', () => {
  it.each([
    ['/chat', 'chat'],
    ['/mail', 'mail'],
    ['/knowledge', 'knowledge'],
    ['/knowledge/life/AGENTS.md', 'knowledge']
  ])('%s -> %s', (pathname, key) => {
    expect(routeKeyFor(pathname)).toBe(key);
  });

  it('returns null for routes that are not pane hosts', () => {
    expect(routeKeyFor('/')).toBeNull();
    expect(routeKeyFor('/calendar')).toBeNull();
  });

  it('ignores params entirely — the key is the route id alone', () => {
    expect(routeKeyFor('/chat')).toBe(routeKeyFor('/chat'));
  });

  // Deeper routes under a host share its memory: the key is the route id, so a
  // subpath must map to the same key rather than to a fresh one.
  it('maps every subpath of a host to that host’s single key', () => {
    expect(routeKeyFor('/chat/archive')).toBe(routeKeyFor('/chat'));
    expect(routeKeyFor('/mail/inbox/42')).toBe('mail');
  });

  // A prefix test without the separator would claim these for the wrong host.
  it('does not match a route that merely starts with a host’s name', () => {
    expect(routeKeyFor('/chatter')).toBeNull();
    expect(routeKeyFor('/knowledgebase')).toBeNull();
    expect(routeKeyFor('/mailbox')).toBeNull();
  });
});

describe('pane persistence', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('round-trips a composition', () => {
    savePanes('chat', [files, chat]);
    expect(loadPanes('chat')).toEqual([files, chat]);
  });

  it('keeps routes independent', () => {
    savePanes('chat', [files]);
    savePanes('mail', [chat]);
    expect(loadPanes('chat')).toEqual([files]);
    expect(loadPanes('mail')).toEqual([chat]);
  });

  it('returns an empty list when nothing was stored', () => {
    expect(loadPanes('knowledge')).toEqual([]);
  });

  it('discards a stored entry with a mismatched version', () => {
    localStorage.setItem(
      'valea.content.chat',
      JSON.stringify({ v: 99, panes: [serializePaneParam(chat)] })
    );
    expect(loadPanes('chat')).toEqual([]);
  });

  it('drops an unparseable descriptor but keeps its valid siblings', () => {
    localStorage.setItem(
      'valea.content.chat',
      JSON.stringify({ v: 1, panes: ['garbage', serializePaneParam(chat)] })
    );
    expect(loadPanes('chat')).toEqual([chat]);
  });

  it('survives malformed JSON', () => {
    localStorage.setItem('valea.content.chat', '{not json');
    expect(loadPanes('chat')).toEqual([]);
  });

  // Asserted on RAW storage rather than through `loadPanes`, which would accept
  // any envelope its own reader happens to understand. The key, the version and
  // the wire form of each pane are the compatibility surface.
  it('writes a versioned envelope of wire forms under the route’s own key', () => {
    savePanes('chat', [files, chat]);
    expect(JSON.parse(localStorage.getItem('valea.content.chat')!)).toEqual({
      v: 1,
      panes: ['files:life/A.md', 'chat:s1']
    });
  });

  it('rejects an envelope whose panes are not a list', () => {
    localStorage.setItem('valea.content.chat', JSON.stringify({ v: 1, panes: 'chat:s1' }));
    expect(loadPanes('chat')).toEqual([]);
  });

  it('stores an emptied composition rather than leaving the old one behind', () => {
    savePanes('chat', [chat]);
    savePanes('chat', []);
    expect(loadPanes('chat')).toEqual([]);
  });
});

describe('chrome preferences', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('defaults both navigators to visible for files and hidden for chat', () => {
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: false } });
  });

  it('round-trips a change', () => {
    saveChrome({ files: { tree: false }, chat: { sessions: true } });
    expect(loadChrome()).toEqual({ files: { tree: false }, chat: { sessions: true } });
  });

  it('falls back to defaults on malformed storage', () => {
    localStorage.setItem('valea.pane-chrome', '[]');
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: false } });
  });

  // `let chrome = $state(loadChrome())` followed by a toggle is the obvious
  // Svelte 5 call site. If any path hands out the module-level constant, that
  // toggle rewrites the shipped default for the life of the process — so an
  // empty profile, an SSR render or a cleared storage would load the wrong one,
  // and in a long-lived Tauri process it never heals.
  it('never hands out the shared default object', () => {
    const first = loadChrome();
    const second = loadChrome();
    expect(first).not.toBe(second);
    expect(first.files).not.toBe(second.files);
    expect(first.chat).not.toBe(second.chat);
  });

  it('is unaffected by a caller mutating what it returned', () => {
    const first = loadChrome();
    first.files.tree = false;
    first.chat.sessions = true;
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: false } });
  });

  it('is unaffected by a caller mutating a partially-stored result', () => {
    localStorage.setItem('valea.pane-chrome', JSON.stringify({ files: { tree: false } }));
    const partial = loadChrome();
    partial.chat.sessions = true;
    localStorage.clear();
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: false } });
  });

  // A preference added in a later version must not drag the older one back to
  // its default when an old entry is read.
  it('fills only the missing half of a partial entry', () => {
    localStorage.setItem('valea.pane-chrome', JSON.stringify({ files: { tree: false } }));
    expect(loadChrome()).toEqual({ files: { tree: false }, chat: { sessions: false } });
    localStorage.setItem('valea.pane-chrome', JSON.stringify({ chat: { sessions: true } }));
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: true } });
  });
});

// Panes are read on the server too, where there is no storage at all. Losing
// the memory is correct there; throwing would take the whole render down.
describe('pane memory — no localStorage (SSR/guard)', () => {
  beforeEach(() => removeLocalStorage());

  it('degrades to empty memory and swallows the failed writes', () => {
    expect(loadPanes('chat')).toEqual([]);
    expect(loadChrome()).toEqual({ files: { tree: true }, chat: { sessions: false } });
    expect(() => savePanes('chat', [chat])).not.toThrow();
    expect(() => saveChrome({ files: { tree: false }, chat: { sessions: true } })).not.toThrow();
    // The nav is the app's only way between routes: with no storage to read,
    // "showing" is the only safe answer.
    expect(loadNavVisible()).toBe(true);
    expect(() => saveNavVisible(false)).not.toThrow();
  });
});

describe('nav visibility', () => {
  beforeEach(() => {
    installFakeLocalStorage();
    localStorage.clear();
  });
  afterEach(() => removeLocalStorage());

  it('defaults to showing when nothing has been stored', () => {
    expect(loadNavVisible()).toBe(true);
  });

  it('round-trips a collapse and a re-open', () => {
    saveNavVisible(false);
    expect(loadNavVisible()).toBe(false);
    saveNavVisible(true);
    expect(loadNavVisible()).toBe(true);
  });

  it('treats anything other than an explicit 0 as showing', () => {
    // Nothing but a deliberate collapse may hide the only navigation the app
    // has, so a value written by an older build (or by hand) fails open.
    localStorage.setItem('valea.nav-visible', 'false');
    expect(loadNavVisible()).toBe(true);
    localStorage.setItem('valea.nav-visible', '');
    expect(loadNavVisible()).toBe(true);
  });
});
