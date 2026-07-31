# Composable Views Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the Valea content area hold a row of panes — the route's primary view plus up to two more — so the file browser, a chat and a file can be on screen together, and mail can sit beside a chat.

**Architecture:** The shell learns exactly one new thing: it renders a *row* of panes instead of a primary plus one. Everything else is pushed inside the panes. Each pane is a navigator plus its content and owns both (Files = tree + up to two file splits; Mail = message list + reader; Chat = sessions list + transcript), so the shell never has to keep a tree in sync with a file view. Panes live in the URL as repeated `?pane=` params, which makes a single `?pane=` — every link in the wild today — a one-element list with no special case.

**Tech Stack:** SvelteKit 2 + Svelte 5 (runes: `$props`, `$state`, `$derived`, `$effect`), TypeScript, Tailwind 4, `paneforge` (`PaneGroup`/`Pane`/`PaneResizer`), vitest, bun.

**Spec:** `docs/superpowers/specs/2026-07-31-composable-views-design.md`. Read it before starting; this plan implements it and does not restate its reasoning.

## Global Constraints

- **Test command:** `cd frontend && bun run test` (vitest). Single file: `bun run test src/lib/panes/pane-route.test.ts`.
- **Typecheck command:** `cd frontend && bun run check` (svelte-kit sync + svelte-check). Must pass with zero errors before every commit.
- **NEVER run prettier or any formatter on `frontend/`.** The frontend has no prettier config; running it bare reformats the entire tree. The backend's `mix format` hook does not apply here.
- **No component render harness.** The codebase convention is pure logic extracted into `.ts` with a `.test.ts` sibling (`pane-route.test.ts`, `pane-split.test.ts`, `icm-route.test.ts`). Components are verified by `bun run check` plus browser verification, never by a mounting test.
- **Pane cap: 2** side panes beside the primary. **Split cap: 2** files inside a Files pane.
- **Widths:** nav 236px · primary min 380px · side pane min 300px · Files tree 240px fixed · file split min 300px.
- **Light theme only** (standing decision). Colour tokens come from `frontend/src/routes/layout.css`: `--paper-*` surfaces, `--ink-*` text, `--act`/`--suggest`/`--warn` for consequence.
- **No accent colour on the bottom bar.** In this design system colour means consequence (`PRODUCT.md` principle 1) and opening a view has none. Inactive `text-ink-meta`, active `text-ink-heading`.
- **Hit targets** ≥ 32px in dense lists, 36px elsewhere.
- **No emoji or exclamation marks in product copy.** Plain language; buttons name outcomes.
- Every commit message ends with:
  ```
  Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
  ```

## File Structure

**New pure-logic modules** (each one file, one responsibility, each with a `.test.ts` sibling):

| File | Responsible for |
|---|---|
| `frontend/src/lib/shell/pane-fit.ts` | width → how many panes and splits fit |
| `frontend/src/lib/shell/reveal-path.ts` | ancestor hrefs of a file, for `treeOpenState` |
| `frontend/src/lib/panes/files-pane-state.ts` | open splits, split cap, tree-click target rule |
| `frontend/src/lib/panes/auto-open.ts` | the three-step assistant auto-open rule |
| `frontend/src/lib/panes/pane-memory.ts` | per-route pane persistence + chrome prefs |

**New components:**

| File | Responsible for |
|---|---|
| `frontend/src/lib/components/panes/FilesPane.svelte` | tree + splits + the split→`FileView` ref map |
| `frontend/src/lib/components/panes/FilesPaneControls.svelte` | tree toggle + `＋ Split`, rendered in `PaneHost`'s header |
| `frontend/src/lib/components/panes/MailPane.svelte` | message list + reader, used by pane *and* `/mail` |
| `frontend/src/lib/components/panes/ChatPane.svelte` | sessions navigator + `ChatView` |
| `frontend/src/lib/components/panes/ChatPaneControls.svelte` | sessions-list toggle |
| `frontend/src/lib/components/shell/ContentBar.svelte` | the bottom bar and its `＋ Pane` menu |

**Modified:** `lib/panes/pane-route.ts`, `pane-split.ts`, `registry.ts`, `context.ts`, `components/panes/PaneHost.svelte`, `components/shell/AppShell.svelte`, `AppFrame.svelte`, `IcmTree.svelte`, and the three routes.

**Deleted:** `lib/components/panes/FilePaneAdapter.svelte` (absorbed by `FilesPane`).

---

### Task 1: Multi-pane URL codec

**Files:**
- Modify: `frontend/src/lib/panes/pane-route.ts`
- Test: `frontend/src/lib/panes/pane-route.test.ts`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  ```ts
  export const PANE_CAP = 2;
  export type FilesPaneDescriptor = { kind: 'files'; mountKey: string; paths: string[] };
  export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
  export type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string };
  export type MailPaneDescriptor = { kind: 'mail'; account: string; msgId: string | null };
  export type PaneDescriptor =
    | FilesPaneDescriptor | ChatPaneDescriptor | ChatNewPaneDescriptor | MailPaneDescriptor;

  export function parsePaneParam(raw: string | null): PaneDescriptor | null;
  export function serializePaneParam(d: PaneDescriptor): string;
  export function parsePanes(searchParams: URLSearchParams): PaneDescriptor[];
  export function withPanes(url: URL, panes: PaneDescriptor[]): string;
  export function panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean;
  export function dedupeSurfaces(
    primary: PaneDescriptor | null, panes: PaneDescriptor[]
  ): PaneDescriptor[];
  export function paneTitle(d: PaneDescriptor): string;
  export function chatNavigatorFromUrl(url: URL): boolean;
  ```

**Context:** The existing file already has `parsePaneParam`/`serializePaneParam`/`panesEqual`/`paneTitle`/`promoteHref` and a `file:` kind. This task replaces `file:` with `files:` (which carries 0–2 paths), adds `mail:`, and adds the list-level functions. `promoteHref` is rewritten in Task 5 — leave it compiling for now by having it handle the new kinds with a `TODO`-free minimal mapping (shown below).

Wire forms, each path segment and the mount key independently `encodeURIComponent`-encoded:

```
files:<mount>                    → { kind:'files', mountKey, paths: [] }
files:<mount>/<p1>               → { kind:'files', mountKey, paths: [p1] }
files:<mount>/<p1>|<p2>          → { kind:'files', mountKey, paths: [p1, p2] }
chat:<sessionId>                 → { kind:'chat', sessionId }
chat:new:<mount>                 → { kind:'chat-new', mountKey }
mail:<account>                   → { kind:'mail', account, msgId: null }
mail:<account>/<msgId>           → { kind:'mail', account, msgId }
```

`|` is safe as the split separator because `encodeURIComponent('|') === '%7C'`, so a literal pipe in a filename never collides with it.

- [ ] **Step 1: Write the failing tests**

Replace the `file` fixture and the `'mail:x'` entry in the existing invalid-input list (it is currently expected to be `null` and must now parse), then add:

```ts
// frontend/src/lib/panes/pane-route.test.ts
import { describe, expect, it } from 'vitest';
import {
  PANE_CAP,
  chatNavigatorFromUrl,
  dedupeSurfaces,
  panesEqual,
  parsePaneParam,
  parsePanes,
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
    const d: PaneDescriptor = { kind: 'files', mountKey: 'm.key', paths: ['ä folder/ünïcode/100%.md'] };
    expect(parsePaneParam(serializePaneParam(d))).toEqual(d);
  });
});

describe('parsePaneParam fails closed', () => {
  it.each([
    null, '', 'files', 'files:', 'files:/no-mount', 'files:m/', 'files:m/a||b',
    'chat:', 'chat:new:', 'mail:', 'mail:/8842', ':x', 'files:m/%E0%A4%A',
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: FAIL — `parsePanes`, `withPanes`, `dedupeSurfaces`, `chatNavigatorFromUrl`, `PANE_CAP` are not exported.

- [ ] **Step 3: Implement the codec**

In `frontend/src/lib/panes/pane-route.ts`, replace the `FilePaneDescriptor` type and the `file` branches, and add the list functions:

```ts
export const PANE_CAP = 2;
const SPLIT_SEP = '|';

export type FilesPaneDescriptor = { kind: 'files'; mountKey: string; paths: string[] };
export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
export type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string };
export type MailPaneDescriptor = { kind: 'mail'; account: string; msgId: string | null };
export type PaneDescriptor =
  | FilesPaneDescriptor
  | ChatPaneDescriptor
  | ChatNewPaneDescriptor
  | MailPaneDescriptor;

function tryDecode(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

/** Decodes one `/`-joined, per-segment-encoded path. `null` if any segment is empty or malformed. */
function decodePath(raw: string): string | null {
  if (raw === '') return null;
  const segments = raw.split('/').map(tryDecode);
  if (segments.some((s) => s === null || s === '')) return null;
  return (segments as string[]).join('/');
}

export function parsePaneParam(raw: string | null): PaneDescriptor | null {
  if (!raw) return null;
  const colon = raw.indexOf(':');
  if (colon <= 0) return null;
  const kind = raw.slice(0, colon);
  const rest = raw.slice(colon + 1);

  if (kind === 'files') {
    const slash = rest.indexOf('/');
    const mountRaw = slash === -1 ? rest : rest.slice(0, slash);
    const mountKey = mountRaw ? tryDecode(mountRaw) : null;
    if (!mountKey) return null;
    if (slash === -1) return { kind: 'files', mountKey, paths: [] };

    const tail = rest.slice(slash + 1);
    if (tail === '') return null;
    const rawPaths = tail.split(SPLIT_SEP);
    if (rawPaths.length > 2) return null;
    const paths = rawPaths.map(decodePath);
    if (paths.some((p) => p === null)) return null;
    return { kind: 'files', mountKey, paths: paths as string[] };
  }

  if (kind === 'chat') {
    if (rest.startsWith('new:')) {
      const mountKey = tryDecode(rest.slice('new:'.length));
      return mountKey ? { kind: 'chat-new', mountKey } : null;
    }
    const sessionId = tryDecode(rest);
    return sessionId ? { kind: 'chat', sessionId } : null;
  }

  if (kind === 'mail') {
    const slash = rest.indexOf('/');
    const accountRaw = slash === -1 ? rest : rest.slice(0, slash);
    const account = accountRaw ? tryDecode(accountRaw) : null;
    if (!account) return null;
    if (slash === -1) return { kind: 'mail', account, msgId: null };
    const msgId = tryDecode(rest.slice(slash + 1));
    return msgId ? { kind: 'mail', account, msgId } : null;
  }

  return null;
}

export function serializePaneParam(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files': {
      const mount = encodeURIComponent(d.mountKey);
      if (d.paths.length === 0) return `files:${mount}`;
      return `files:${mount}/${d.paths.map(encodePath).join(SPLIT_SEP)}`;
    }
    case 'chat':
      return `chat:${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `chat:new:${encodeURIComponent(d.mountKey)}`;
    case 'mail':
      return d.msgId === null
        ? `mail:${encodeURIComponent(d.account)}`
        : `mail:${encodeURIComponent(d.account)}/${encodeURIComponent(d.msgId)}`;
  }
}

/** Identity comparison. Null never equals anything, including null. */
export function panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  return serializePaneParam(a) === serializePaneParam(b);
}

/**
 * One surface per descriptor kind across `[primary, ...panes]`, regardless of
 * subject. Coarser than `panesEqual` and wins where they disagree: `/knowledge`
 * has a null primary descriptor, so identity alone would let a redundant Files
 * pane through.
 */
export function dedupeSurfaces(
  primary: PaneDescriptor | null,
  panes: PaneDescriptor[]
): PaneDescriptor[] {
  const seen = new Set<string>(primary ? [primary.kind] : []);
  const out: PaneDescriptor[] = [];
  for (const pane of panes) {
    if (seen.has(pane.kind)) continue;
    seen.add(pane.kind);
    out.push(pane);
  }
  return out;
}

/** Every valid `pane` param, in document order, deduped and capped. Fails closed per entry. */
export function parsePanes(searchParams: URLSearchParams): PaneDescriptor[] {
  const parsed = searchParams
    .getAll('pane')
    .map(parsePaneParam)
    .filter((d): d is PaneDescriptor => d !== null);
  return dedupeSurfaces(null, parsed).slice(0, PANE_CAP);
}

/** `goto` target for `url` with its pane params replaced. Every other param survives. */
export function withPanes(url: URL, panes: PaneDescriptor[]): string {
  const next = new URL(url);
  next.searchParams.delete('pane');
  for (const pane of panes.slice(0, PANE_CAP)) {
    next.searchParams.append('pane', serializePaneParam(pane));
  }
  return next.pathname + next.search;
}

/** Legacy `?all=1`: the chat primary's sessions navigator. */
export function chatNavigatorFromUrl(url: URL): boolean {
  return url.searchParams.get('all') === '1';
}

export function paneTitle(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      return d.paths.length ? (d.paths[0].split('/').pop() ?? 'Files') : 'Files';
    case 'chat':
      return 'Chat';
    case 'chat-new':
      return 'New session';
    case 'mail':
      return 'Mail';
  }
}
```

Also update `promoteHref` so the file still typechecks — Task 5 replaces it entirely:

```ts
export function promoteHref(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files':
      return d.paths.length ? knowledgeHref(d.mountKey, d.paths[0]) : `/knowledge?icm=${encodeURIComponent(d.mountKey)}`;
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `/chat?icm=${encodeURIComponent(d.mountKey)}`;
    case 'mail':
      return d.msgId === null
        ? `/mail?account=${encodeURIComponent(d.account)}`
        : `/mail?account=${encodeURIComponent(d.account)}&message=${encodeURIComponent(d.msgId)}`;
  }
}
```

Delete `withPaneParam`, `paneLinkSearch` and `hrefWithPane` only after Task 9 stops using them; for now leave them, rewriting their internals to call `withPanes` with a one-element list.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: PASS, all cases.

- [ ] **Step 5: Typecheck**

Run: `cd frontend && bun run check`
Expected: errors only in files that consume the old `file:` kind (`registry.ts`, `FilePaneAdapter.svelte`, the three routes). Those are fixed in later tasks. Note the exact list in the commit message so the next task knows what is outstanding.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/panes/pane-route.ts frontend/src/lib/panes/pane-route.test.ts
git commit -m "feat(panes): multi-pane URL codec — repeated ?pane=, files: and mail: kinds

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Width fitting and per-count split ratios

**Files:**
- Create: `frontend/src/lib/shell/pane-fit.ts`
- Create: `frontend/src/lib/shell/pane-fit.test.ts`
- Modify: `frontend/src/lib/panes/pane-split.ts`
- Modify: `frontend/src/lib/panes/pane-split.test.ts`

**Interfaces:**
- Consumes: `PaneDescriptor`, `PANE_CAP` from Task 1.
- Produces:
  ```ts
  export const NAV_W = 236;
  export const PRIMARY_MIN = 380;
  export const PANE_MIN = 300;
  export const TREE_W = 240;
  export const SPLIT_MIN = 300;
  export function panesThatFit(windowWidth: number, navVisible: boolean): number;
  export function splitsThatFit(paneWidth: number, treeVisible: boolean): number;
  export function truncateToFit(
    panes: PaneDescriptor[], windowWidth: number, navVisible: boolean
  ): PaneDescriptor[];
  // pane-split.ts
  export function loadPaneLayout(count: number): number[] | null;
  export function savePaneLayout(count: number, layout: number[]): void;
  export function loadFilesSplit(): number;
  export function saveFilesSplit(pct: number): void;
  ```

**Context:** `pane-fit.ts` is consulted **only** when a pane or split is added or restored — never on resize. Nothing is ever hidden-but-mounted, so requested, mounted and visible counts are always equal.

- [ ] **Step 1: Write the failing tests**

```ts
// frontend/src/lib/shell/pane-fit.test.ts
import { describe, expect, it } from 'vitest';
import { panesThatFit, splitsThatFit, truncateToFit } from './pane-fit';
import type { PaneDescriptor } from '$lib/panes/pane-route';

const a: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: [] };
const b: PaneDescriptor = { kind: 'chat', sessionId: 's1' };

describe('panesThatFit', () => {
  it('fits none when only the primary clears its minimum', () => {
    expect(panesThatFit(236 + 380, true)).toBe(0);
    expect(panesThatFit(900, true)).toBe(0);
  });

  it('fits one at primary + pane minimums', () => {
    expect(panesThatFit(236 + 380 + 300, true)).toBe(1);
  });

  it('fits two at primary + two pane minimums', () => {
    expect(panesThatFit(236 + 380 + 300 + 300, true)).toBe(2);
  });

  it('never exceeds the cap however wide the window', () => {
    expect(panesThatFit(6000, true)).toBe(2);
  });

  it('reclaims the nav width when the nav is collapsed', () => {
    expect(panesThatFit(380 + 300, false)).toBe(1);
  });

  it('is never negative on absurdly small windows', () => {
    expect(panesThatFit(0, true)).toBe(0);
  });
});

describe('splitsThatFit', () => {
  it('fits one split beside the tree', () => {
    expect(splitsThatFit(240 + 300, true)).toBe(1);
  });

  it('fits two splits beside the tree', () => {
    expect(splitsThatFit(240 + 300 + 300, true)).toBe(2);
  });

  it('reclaims the tree width when the tree is hidden', () => {
    expect(splitsThatFit(300 + 300, false)).toBe(2);
  });

  it('caps at two', () => {
    expect(splitsThatFit(4000, true)).toBe(2);
  });

  it('fits none when even one split would not clear its minimum', () => {
    expect(splitsThatFit(240 + 100, true)).toBe(0);
  });
});

describe('truncateToFit', () => {
  it('truncates from the right', () => {
    expect(truncateToFit([a, b], 236 + 380 + 300, true)).toEqual([a]);
  });

  it('returns everything when it all fits', () => {
    expect(truncateToFit([a, b], 1600, true)).toEqual([a, b]);
  });

  it('returns nothing when not even one pane fits', () => {
    expect(truncateToFit([a, b], 700, true)).toEqual([]);
  });
});
```

```ts
// append to frontend/src/lib/panes/pane-split.test.ts
import { loadFilesSplit, loadPaneLayout, saveFilesSplit, savePaneLayout } from './pane-split';

describe('per-count pane layouts', () => {
  beforeEach(() => localStorage.clear());

  it('keeps two-pane and three-pane arrangements independently', () => {
    savePaneLayout(2, [60, 40]);
    savePaneLayout(3, [50, 25, 25]);
    expect(loadPaneLayout(2)).toEqual([60, 40]);
    expect(loadPaneLayout(3)).toEqual([50, 25, 25]);
  });

  it('returns null for a count never saved, so the group uses its defaults', () => {
    expect(loadPaneLayout(3)).toBeNull();
  });

  it('rejects a stored layout whose length no longer matches the count', () => {
    localStorage.setItem('valea.pane-split.2', JSON.stringify([50, 25, 25]));
    expect(loadPaneLayout(2)).toBeNull();
  });

  it('rejects a stored layout containing a non-finite entry', () => {
    localStorage.setItem('valea.pane-split.2', JSON.stringify([50, null]));
    expect(loadPaneLayout(2)).toBeNull();
  });

  it('persists the Files pane split ratio under its own key', () => {
    saveFilesSplit(45);
    expect(loadFilesSplit()).toBe(45);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/shell/pane-fit.test.ts src/lib/panes/pane-split.test.ts`
Expected: FAIL — `pane-fit.ts` does not exist; `loadPaneLayout` is not exported.

- [ ] **Step 3: Implement both modules**

```ts
// frontend/src/lib/shell/pane-fit.ts
/**
 * Width arithmetic for the pane row. Consulted ONLY when a pane or split is
 * added or restored — never on resize. See the spec's "Width behaviour":
 * continuous auto-hide would mean unmounting a mounted `ChatView`, which
 * disposes its `AgentSessionStore` and drops the composer's draft.
 */
import { PANE_CAP, type PaneDescriptor } from '$lib/panes/pane-route';

export const NAV_W = 236;
export const PRIMARY_MIN = 380;
export const PANE_MIN = 300;
export const TREE_W = 240;
export const SPLIT_MIN = 300;

const SPLIT_CAP = 2;

export function panesThatFit(windowWidth: number, navVisible: boolean): number {
  const spare = windowWidth - (navVisible ? NAV_W : 0) - PRIMARY_MIN;
  if (spare < 0) return 0;
  return Math.min(PANE_CAP, Math.floor(spare / PANE_MIN));
}

export function splitsThatFit(paneWidth: number, treeVisible: boolean): number {
  const spare = paneWidth - (treeVisible ? TREE_W : 0);
  if (spare < 0) return 0;
  return Math.min(SPLIT_CAP, Math.floor(spare / SPLIT_MIN));
}

/** Drops panes from the right until the rest fit. Callers keep the full list in memory. */
export function truncateToFit(
  panes: PaneDescriptor[],
  windowWidth: number,
  navVisible: boolean
): PaneDescriptor[] {
  return panes.slice(0, panesThatFit(windowWidth, navVisible));
}
```

```ts
// frontend/src/lib/panes/pane-split.ts — replace the whole file
/**
 * Persisted pane-row layouts, one per pane COUNT, plus the Files pane's
 * internal tree/splits ratio. Same guarded-storage posture as before: a
 * storage failure (SSR, private mode) degrades to defaults, never an error.
 *
 * Keyed by count because going from two columns to three and back must not
 * lose either arrangement. The count is unambiguous — nothing is ever
 * hidden-but-mounted, so requested, mounted and visible panes are one set.
 */
const LAYOUT_PREFIX = 'valea.pane-split.';
const FILES_KEY = 'valea.files-split';
const FILES_DEFAULT = 40;
const FILES_MIN = 20;
const FILES_MAX = 70;

function clampFiles(pct: number): number {
  return Math.min(FILES_MAX, Math.max(FILES_MIN, Math.round(pct)));
}

export function loadPaneLayout(count: number): number[] | null {
  try {
    const raw = localStorage.getItem(LAYOUT_PREFIX + count);
    if (raw === null) return null;
    const parsed: unknown = JSON.parse(raw);
    if (!Array.isArray(parsed) || parsed.length !== count) return null;
    if (!parsed.every((n) => typeof n === 'number' && Number.isFinite(n))) return null;
    return parsed as number[];
  } catch {
    return null;
  }
}

export function savePaneLayout(count: number, layout: number[]): void {
  if (layout.length !== count) return;
  if (!layout.every((n) => Number.isFinite(n))) return;
  try {
    localStorage.setItem(LAYOUT_PREFIX + count, JSON.stringify(layout));
  } catch {
    // best-effort persistence only
  }
}

export function loadFilesSplit(): number {
  try {
    const raw = localStorage.getItem(FILES_KEY);
    if (raw === null) return FILES_DEFAULT;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? clampFiles(parsed) : FILES_DEFAULT;
  } catch {
    return FILES_DEFAULT;
  }
}

export function saveFilesSplit(pct: number): void {
  try {
    localStorage.setItem(FILES_KEY, String(clampFiles(pct)));
  } catch {
    // best-effort persistence only
  }
}
```

Remove the old `loadPaneSplit`/`savePaneSplit` tests from `pane-split.test.ts` — those functions are gone — and add `import { beforeEach } from 'vitest'` to the test file.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/shell/pane-fit.test.ts src/lib/panes/pane-split.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/shell/pane-fit.ts frontend/src/lib/shell/pane-fit.test.ts \
        frontend/src/lib/panes/pane-split.ts frontend/src/lib/panes/pane-split.test.ts
git commit -m "feat(panes): pane-fit width rules and per-count split layouts

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Files pane state and path reveal

**Files:**
- Create: `frontend/src/lib/panes/files-pane-state.ts`
- Create: `frontend/src/lib/panes/files-pane-state.test.ts`
- Create: `frontend/src/lib/shell/reveal-path.ts`
- Create: `frontend/src/lib/shell/reveal-path.test.ts`

**Interfaces:**
- Consumes: `knowledgeHref` from `$lib/shell/nav`.
- Produces:
  ```ts
  export const SPLIT_CAP = 2;
  export function openInFirst(paths: string[], path: string, maxSplits: number): string[];
  export function openAsSecond(paths: string[], path: string, maxSplits: number): string[];
  export function closeSplit(paths: string[], index: number): string[];
  export function canAddSplit(paths: string[], maxSplits: number): boolean;
  export function dropVanished(paths: string[], vanished: string): string[];
  // reveal-path.ts
  export function ancestorHrefs(mountKey: string, path: string): string[];
  ```

**Context:** These are the rules the middle draft needed shell-level machinery for. `ancestorHrefs` is lifted out of `routes/knowledge/[...path]/+page.svelte:105-115`, which currently inlines the same loop where only that route can use it.

- [ ] **Step 1: Write the failing tests**

```ts
// frontend/src/lib/panes/files-pane-state.test.ts
import { describe, expect, it } from 'vitest';
import {
  canAddSplit,
  closeSplit,
  dropVanished,
  openAsSecond,
  openInFirst
} from './files-pane-state';

describe('openInFirst', () => {
  it('opens into an empty pane', () => {
    expect(openInFirst([], 'A.md', 2)).toEqual(['A.md']);
  });

  it('replaces the first split, leaving the second alone', () => {
    expect(openInFirst(['A.md', 'B.md'], 'C.md', 2)).toEqual(['C.md', 'B.md']);
  });

  it('is a no-op when the file is already in the first split', () => {
    expect(openInFirst(['A.md'], 'A.md', 2)).toEqual(['A.md']);
  });

  it('moves focus rather than duplicating when the file is already in the second split', () => {
    expect(openInFirst(['A.md', 'B.md'], 'B.md', 2)).toEqual(['A.md', 'B.md']);
  });
});

describe('openAsSecond', () => {
  it('adds a second split', () => {
    expect(openAsSecond(['A.md'], 'B.md', 2)).toEqual(['A.md', 'B.md']);
  });

  it('replaces the second when both are taken', () => {
    expect(openAsSecond(['A.md', 'B.md'], 'C.md', 2)).toEqual(['A.md', 'C.md']);
  });

  it('behaves like openInFirst on an empty pane', () => {
    expect(openAsSecond([], 'A.md', 2)).toEqual(['A.md']);
  });

  it('refuses to exceed the width-derived cap', () => {
    expect(openAsSecond(['A.md'], 'B.md', 1)).toEqual(['B.md']);
  });

  it('never duplicates an already-open file', () => {
    expect(openAsSecond(['A.md'], 'A.md', 2)).toEqual(['A.md']);
  });
});

describe('closeSplit', () => {
  it('removes the split at the index', () => {
    expect(closeSplit(['A.md', 'B.md'], 0)).toEqual(['B.md']);
    expect(closeSplit(['A.md', 'B.md'], 1)).toEqual(['A.md']);
  });

  it('leaves a tree-only pane when the last split closes', () => {
    expect(closeSplit(['A.md'], 0)).toEqual([]);
  });

  it('ignores an out-of-range index', () => {
    expect(closeSplit(['A.md'], 3)).toEqual(['A.md']);
  });
});

describe('canAddSplit', () => {
  it('is false at the cap and true below it', () => {
    expect(canAddSplit(['A.md', 'B.md'], 2)).toBe(false);
    expect(canAddSplit(['A.md'], 2)).toBe(true);
    expect(canAddSplit(['A.md'], 1)).toBe(false);
  });
});

describe('dropVanished', () => {
  it('removes only the vanished file, keeping its sibling', () => {
    expect(dropVanished(['A.md', 'B.md'], 'A.md')).toEqual(['B.md']);
  });

  it('leaves the list untouched when nothing matches', () => {
    expect(dropVanished(['A.md'], 'Z.md')).toEqual(['A.md']);
  });
});
```

```ts
// frontend/src/lib/shell/reveal-path.test.ts
import { describe, expect, it } from 'vitest';
import { ancestorHrefs } from './reveal-path';

describe('ancestorHrefs', () => {
  it('lists every folder above the file, outermost first', () => {
    expect(ancestorHrefs('life', 'finances/records/income/jan.md')).toEqual([
      '/knowledge/life/finances',
      '/knowledge/life/finances/records',
      '/knowledge/life/finances/records/income'
    ]);
  });

  it('returns nothing for a file at the mount root', () => {
    expect(ancestorHrefs('life', 'AGENTS.md')).toEqual([]);
  });

  it('encodes each segment independently', () => {
    expect(ancestorHrefs('m.key', 'ä folder/x.md')).toEqual(['/knowledge/m.key/%C3%A4%20folder']);
  });

  it('returns nothing for an empty path', () => {
    expect(ancestorHrefs('life', '')).toEqual([]);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/panes/files-pane-state.test.ts src/lib/shell/reveal-path.test.ts`
Expected: FAIL — neither module exists.

- [ ] **Step 3: Implement both modules**

```ts
// frontend/src/lib/panes/files-pane-state.ts
/**
 * Pure rules for what a Files pane has open. The pane owns this state
 * privately — nothing outside it can observe the relationship between the
 * tree and the splits, which is the whole point of the self-contained-pane
 * design.
 *
 * `maxSplits` is the width-derived cap from `pane-fit.ts`'s `splitsThatFit`,
 * never a constant: a narrow pane genuinely holds fewer splits than a wide one.
 */
export const SPLIT_CAP = 2;

/** A tree click. Replaces the first split; an already-open file is left where it is. */
export function openInFirst(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  if (paths.length === 0) return maxSplits >= 1 ? [path] : [];
  return [path, ...paths.slice(1)].slice(0, Math.max(1, maxSplits));
}

/** The row's "open beside" affordance. Adds a second split, or replaces it when full. */
export function openAsSecond(paths: string[], path: string, maxSplits: number): string[] {
  if (paths.includes(path)) return paths;
  if (paths.length === 0) return maxSplits >= 1 ? [path] : [];
  if (paths.length < maxSplits) return [...paths, path];
  return [...paths.slice(0, Math.max(0, maxSplits - 1)), path];
}

export function closeSplit(paths: string[], index: number): string[] {
  if (index < 0 || index >= paths.length) return paths;
  return paths.filter((_, i) => i !== index);
}

export function canAddSplit(paths: string[], maxSplits: number): boolean {
  return paths.length < Math.min(SPLIT_CAP, maxSplits);
}

/** A split whose file was deleted. Its sibling survives — see the spec's per-subject rule. */
export function dropVanished(paths: string[], vanished: string): string[] {
  return paths.filter((p) => p !== vanished);
}
```

```ts
// frontend/src/lib/shell/reveal-path.ts
/**
 * Every folder href above a file, outermost first — what `treeOpenState.open()`
 * needs to reveal a file's ancestors. Lifted out of
 * `routes/knowledge/[...path]/+page.svelte`, where it was inlined and so
 * unavailable to any other pane host.
 */
import { knowledgeHref } from './nav';

export function ancestorHrefs(mountKey: string, path: string): string[] {
  if (!path) return [];
  const segments = path.split('/');
  const hrefs: string[] = [];
  for (let i = 0; i < segments.length - 1; i++) {
    hrefs.push(knowledgeHref(mountKey, segments.slice(0, i + 1).join('/')));
  }
  return hrefs;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/panes/files-pane-state.test.ts src/lib/shell/reveal-path.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/panes/files-pane-state.ts frontend/src/lib/panes/files-pane-state.test.ts \
        frontend/src/lib/shell/reveal-path.ts frontend/src/lib/shell/reveal-path.test.ts
git commit -m "feat(panes): Files pane split rules and shared ancestor reveal

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Auto-open rule and pane memory

**Files:**
- Create: `frontend/src/lib/panes/auto-open.ts`
- Create: `frontend/src/lib/panes/auto-open.test.ts`
- Create: `frontend/src/lib/panes/pane-memory.ts`
- Create: `frontend/src/lib/panes/pane-memory.test.ts`

**Interfaces:**
- Consumes: `openAsSecond` from Task 3; `PaneDescriptor`, `parsePaneParam`, `serializePaneParam` from Task 1.
- Produces:
  ```ts
  export type AutoOpen = { paths: string[]; autoIndex: number | null };
  export function autoOpen(
    paths: string[], autoIndex: number | null, path: string, maxSplits: number
  ): AutoOpen;
  export function clearAuto(autoIndex: number | null, userIndex: number): number | null;
  // pane-memory.ts
  export type RouteKey = 'chat' | 'mail' | 'knowledge';
  export type PaneChrome = { files: { tree: boolean }; chat: { sessions: boolean } };
  export function routeKeyFor(pathname: string): RouteKey | null;
  export function loadPanes(key: RouteKey): PaneDescriptor[];
  export function savePanes(key: RouteKey, panes: PaneDescriptor[]): void;
  export function loadChrome(): PaneChrome;
  export function saveChrome(chrome: PaneChrome): void;
  ```

**Context:** The auto-open rule is the three-step one from the spec — recycle the assistant's own split, else take a free slot, else do nothing. It never evicts a file the user placed. Route keys are the route id alone, never qualified by params.

- [ ] **Step 1: Write the failing tests**

```ts
// frontend/src/lib/panes/auto-open.test.ts
import { describe, expect, it } from 'vitest';
import { autoOpen, clearAuto } from './auto-open';

describe('autoOpen', () => {
  it('opens into an empty pane and claims that split', () => {
    expect(autoOpen([], null, 'A.md', 2)).toEqual({ paths: ['A.md'], autoIndex: 0 });
  });

  it('takes a free slot rather than replacing a user file', () => {
    expect(autoOpen(['USER.md'], null, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });

  it('recycles its own split instead of accumulating', () => {
    expect(autoOpen(['USER.md', 'A.md'], 1, 'B.md', 2)).toEqual({
      paths: ['USER.md', 'B.md'],
      autoIndex: 1
    });
  });

  it('does nothing when both splits are the user’s', () => {
    expect(autoOpen(['X.md', 'Y.md'], null, 'A.md', 2)).toEqual({
      paths: ['X.md', 'Y.md'],
      autoIndex: null
    });
  });

  it('does nothing when the width allows no split at all', () => {
    expect(autoOpen([], null, 'A.md', 0)).toEqual({ paths: [], autoIndex: null });
  });

  it('is a no-op when the file is already open, without stealing the claim', () => {
    expect(autoOpen(['A.md'], null, 'A.md', 2)).toEqual({ paths: ['A.md'], autoIndex: null });
  });

  it('drops a stale claim pointing past the end of the list', () => {
    expect(autoOpen(['USER.md'], 5, 'A.md', 2)).toEqual({
      paths: ['USER.md', 'A.md'],
      autoIndex: 1
    });
  });
});

describe('clearAuto', () => {
  it('releases the claim when the user opens into that split', () => {
    expect(clearAuto(1, 1)).toBeNull();
  });

  it('keeps the claim when the user opens into a different split', () => {
    expect(clearAuto(1, 0)).toBe(1);
  });

  it('tolerates there being no claim', () => {
    expect(clearAuto(null, 0)).toBeNull();
  });
});
```

```ts
// frontend/src/lib/panes/pane-memory.test.ts
import { beforeEach, describe, expect, it } from 'vitest';
import { loadChrome, loadPanes, routeKeyFor, savePanes, saveChrome } from './pane-memory';
import { serializePaneParam, type PaneDescriptor } from './pane-route';

const chat: PaneDescriptor = { kind: 'chat', sessionId: 's1' };
const files: PaneDescriptor = { kind: 'files', mountKey: 'life', paths: ['A.md'] };

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
});

describe('pane persistence', () => {
  beforeEach(() => localStorage.clear());

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
});

describe('chrome preferences', () => {
  beforeEach(() => localStorage.clear());

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
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/panes/auto-open.test.ts src/lib/panes/pane-memory.test.ts`
Expected: FAIL — neither module exists.

- [ ] **Step 3: Implement both modules**

```ts
// frontend/src/lib/panes/auto-open.ts
/**
 * Where a file the ASSISTANT opened lands inside a Files pane.
 *
 * The rule tracks the one split auto-open created, so the assistant recycles
 * its own while a file the user placed stays put: pin your file on the right
 * and let chat cycle references on the left. Rule 3 is the conservative floor
 * `hasOpenPane()` provides today — auto-open never evicts a user's file.
 */
export type AutoOpen = { paths: string[]; autoIndex: number | null };

export function autoOpen(
  paths: string[],
  autoIndex: number | null,
  path: string,
  maxSplits: number
): AutoOpen {
  if (maxSplits < 1) return { paths, autoIndex: null };
  if (paths.includes(path)) return { paths, autoIndex };

  // 1. Recycle the split auto-open created, if it still exists.
  if (autoIndex !== null && autoIndex < paths.length) {
    const next = [...paths];
    next[autoIndex] = path;
    return { paths: next, autoIndex };
  }

  // 2. Take a free slot.
  if (paths.length < maxSplits) {
    return { paths: [...paths, path], autoIndex: paths.length };
  }

  // 3. Both splits are the user's — do nothing.
  return { paths, autoIndex: null };
}

/** A user-initiated open into `userIndex` releases the assistant's claim on it. */
export function clearAuto(autoIndex: number | null, userIndex: number): number | null {
  return autoIndex === userIndex ? null : autoIndex;
}
```

```ts
// frontend/src/lib/panes/pane-memory.ts
/**
 * Per-route pane memory and per-kind chrome preferences.
 *
 * The route key is the route id ALONE — never qualified by params. Which
 * session, account or mount was open is the primary's business and already
 * lives in the route; qualifying would fragment memory into hundreds of
 * entries that each restore once.
 *
 * Content lives in the URL; chrome is a preference. So which files a Files
 * pane has open travels in the descriptor, while whether its tree shows is
 * stored here and shared by every Files pane.
 *
 * Same guarded-storage posture as `pane-split.ts`: no `localStorage` (SSR,
 * tests) or a write failure just means state is session-local, never an error.
 */
import { parsePaneParam, serializePaneParam, type PaneDescriptor } from './pane-route';

const CONTENT_PREFIX = 'valea.content.';
const CHROME_KEY = 'valea.pane-chrome';
const VERSION = 1;

export type RouteKey = 'chat' | 'mail' | 'knowledge';
export type PaneChrome = { files: { tree: boolean }; chat: { sessions: boolean } };

const CHROME_DEFAULT: PaneChrome = { files: { tree: true }, chat: { sessions: false } };

export function routeKeyFor(pathname: string): RouteKey | null {
  if (pathname === '/chat' || pathname.startsWith('/chat/')) return 'chat';
  if (pathname === '/mail' || pathname.startsWith('/mail/')) return 'mail';
  if (pathname === '/knowledge' || pathname.startsWith('/knowledge/')) return 'knowledge';
  return null;
}

export function loadPanes(key: RouteKey): PaneDescriptor[] {
  try {
    const raw = localStorage.getItem(CONTENT_PREFIX + key);
    if (raw === null) return [];
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null) return [];
    const entry = parsed as { v?: unknown; panes?: unknown };
    if (entry.v !== VERSION || !Array.isArray(entry.panes)) return [];
    return entry.panes
      .map((s) => (typeof s === 'string' ? parsePaneParam(s) : null))
      .filter((d): d is PaneDescriptor => d !== null);
  } catch {
    return [];
  }
}

export function savePanes(key: RouteKey, panes: PaneDescriptor[]): void {
  try {
    localStorage.setItem(
      CONTENT_PREFIX + key,
      JSON.stringify({ v: VERSION, panes: panes.map(serializePaneParam) })
    );
  } catch {
    // best-effort persistence only
  }
}

export function loadChrome(): PaneChrome {
  try {
    const raw = localStorage.getItem(CHROME_KEY);
    if (raw === null) return CHROME_DEFAULT;
    const parsed: unknown = JSON.parse(raw);
    if (typeof parsed !== 'object' || parsed === null || Array.isArray(parsed)) {
      return CHROME_DEFAULT;
    }
    const entry = parsed as Partial<PaneChrome>;
    return {
      files: { tree: entry.files?.tree ?? CHROME_DEFAULT.files.tree },
      chat: { sessions: entry.chat?.sessions ?? CHROME_DEFAULT.chat.sessions }
    };
  } catch {
    return CHROME_DEFAULT;
  }
}

export function saveChrome(chrome: PaneChrome): void {
  try {
    localStorage.setItem(CHROME_KEY, JSON.stringify(chrome));
  } catch {
    // best-effort persistence only
  }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/panes/auto-open.test.ts src/lib/panes/pane-memory.test.ts`
Expected: PASS.

- [ ] **Step 5: Run the whole suite**

Run: `cd frontend && bun run test`
Expected: PASS. All four pure-logic tasks are now green; only component consumers of the old `file:` kind are still broken under `bun run check`.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/panes/auto-open.ts frontend/src/lib/panes/auto-open.test.ts \
        frontend/src/lib/panes/pane-memory.ts frontend/src/lib/panes/pane-memory.test.ts
git commit -m "feat(panes): assistant auto-open rule and per-route pane memory

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Promotion merge rules

**Files:**
- Modify: `frontend/src/lib/panes/pane-route.ts`
- Modify: `frontend/src/lib/panes/pane-route.test.ts`

**Interfaces:**
- Consumes: `withPanes`, `dedupeSurfaces`, `PaneDescriptor` from Task 1.
- Produces:
  ```ts
  export function promoteTarget(
    promoted: PaneDescriptor, url: URL, panes: PaneDescriptor[]
  ): string;
  ```
  (`promoteHref` is deleted; every caller moves to `promoteTarget`.)

**Context:** `promoteHref` currently returns a bare route and drops everything else. Promotion must build the target route with that kind's own params, re-attach the *remaining* panes, and re-run duplicate suppression so the promoted kind does not appear twice. Params belonging to the old primary (`all`, `icm`, `drafts`, `compose`, `setup`, `split`, `session`, `message`, `account`) are not carried across a kind change.

- [ ] **Step 1: Write the failing tests**

```ts
// append to frontend/src/lib/panes/pane-route.test.ts
import { promoteTarget } from './pane-route';

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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: FAIL — `promoteTarget` is not exported.

- [ ] **Step 3: Implement**

Replace `promoteHref` in `frontend/src/lib/panes/pane-route.ts`:

```ts
/**
 * Where "open as full view" (⤢) navigates.
 *
 * Builds the target route with the promoted kind's OWN params, re-attaches the
 * panes that survive, and re-runs surface dedup so the promoted kind cannot
 * appear both as the new primary and beside it. The old primary's params are
 * deliberately dropped — `?session=` means nothing on `/mail`.
 */
export function promoteTarget(
  promoted: PaneDescriptor,
  url: URL,
  panes: PaneDescriptor[]
): string {
  const remaining = dedupeSurfaces(
    promoted,
    panes.filter((p) => !panesEqual(p, promoted))
  );

  const target = new URL(routeFor(promoted), url.origin);
  for (const pane of remaining.slice(0, PANE_CAP)) {
    target.searchParams.append('pane', serializePaneParam(pane));
  }
  return target.pathname + target.search;
}

function routeFor(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'files': {
      if (d.paths.length === 0) return `/knowledge?icm=${encodeURIComponent(d.mountKey)}`;
      const base = knowledgeHref(d.mountKey, d.paths[0]);
      return d.paths.length > 1 ? `${base}?split=${encodePath(d.paths[1])}` : base;
    }
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `/chat?icm=${encodeURIComponent(d.mountKey)}`;
    case 'mail':
      return d.msgId === null
        ? `/mail?account=${encodeURIComponent(d.account)}`
        : `/mail?account=${encodeURIComponent(d.account)}&message=${encodeURIComponent(d.msgId)}`;
  }
}
```

Delete `promoteHref`, `withPaneParam`, `paneLinkSearch` and `hrefWithPane`. Their remaining callers are fixed in Task 9; `bun run check` will list them.

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/panes/pane-route.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/panes/pane-route.ts frontend/src/lib/panes/pane-route.test.ts
git commit -m "feat(panes): promotion carries surviving panes and kind-specific params

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: PaneHost renders N panes; registry gains the PaneEntry contract

**Files:**
- Modify: `frontend/src/lib/components/panes/PaneHost.svelte`
- Modify: `frontend/src/lib/panes/registry.ts`
- Modify: `frontend/src/lib/panes/context.ts`

**Interfaces:**
- Consumes: `PaneDescriptor`, `paneTitle`, `serializePaneParam`, `promoteTarget`, `PANE_CAP` (Tasks 1, 5); `loadPaneLayout`, `savePaneLayout` (Task 2).
- Produces:
  ```ts
  // registry.ts
  export type PaneState = Record<string, unknown> & { dispose?: () => void };
  export type PaneEntry = {
    view: Component<{ descriptor: PaneDescriptor; context: PaneContext; state?: PaneState }>;
    controls?: Component<{ state: PaneState }>;
    createState?: (descriptor: PaneDescriptor) => PaneState;
  };
  export const paneEntries: Record<PaneDescriptor['kind'], PaneEntry>;

  // context.ts
  export type PaneContext = {
    placement: 'primary' | 'pane';
    openFile?: (sel: { mountKey: string; path: string }) => void;
    openPane?: (d: PaneDescriptor) => void;
    sessionCreated?: (id: string) => void;
    onArchived?: () => void;
    onVanished?: (subject: string) => void;
  };
  ```
- Produces (component props):
  ```svelte
  <PaneHost
    primary={Snippet}
    primaryDescriptor={PaneDescriptor | null}
    panes={PaneDescriptor[]}
    paneContext={(d: PaneDescriptor, i: number) => PaneContext}
    onClose={(index: number) => void}
    onPromote={(d: PaneDescriptor) => void}
  />
  ```

**Context:** Per-kind header controls cannot be a snippet handed upward — `PaneHost` renders the header before mounting the view. So the **host** owns per-pane state: it calls `createState(descriptor)` once per pane and passes the result to both the header's `controls` component and the body's `view` component, so neither parents the other.

The unconditional-primary rule in `PaneHost`'s existing header comment is load-bearing and must survive: hosting the primary inside an `{#if}` branch would destroy and rebuild it on every pane change, tearing down the session channel and dropping the composer's draft. Side panes are keyed by their serialized descriptor so a real identity change remounts and a mere re-derive does not.

- [ ] **Step 1: Rewrite the registry**

```ts
// frontend/src/lib/panes/registry.ts
/**
 * kind -> pane entry. THE one place to extend when a new view becomes
 * pane-mountable.
 *
 * An entry is no longer a bare component. `PaneHost` renders the pane header
 * BEFORE mounting the view, so a pane cannot hand stateful chrome upward to
 * its already-rendering parent. Instead the host calls `createState` once per
 * pane and passes the result to both `controls` (in the header) and `view`
 * (in the body). Kinds needing no extras omit both fields and degrade to the
 * old shape.
 */
import type { Component } from 'svelte';
import type { PaneDescriptor } from './pane-route';
import type { PaneContext } from './context';
import FilesPane from '$lib/components/panes/FilesPane.svelte';
import FilesPaneControls from '$lib/components/panes/FilesPaneControls.svelte';
import ChatPane from '$lib/components/panes/ChatPane.svelte';
import ChatPaneControls from '$lib/components/panes/ChatPaneControls.svelte';
import MailPane from '$lib/components/panes/MailPane.svelte';
import { createFilesPaneState, type FilesPaneState } from './files-pane-runtime.svelte';
import { createChatPaneState, type ChatPaneState } from './chat-pane-runtime.svelte';

export type PaneState = FilesPaneState | ChatPaneState;

export type PaneEntry = {
  view: Component<{ descriptor: PaneDescriptor; context: PaneContext; state?: PaneState }>;
  controls?: Component<{ state: PaneState }>;
  createState?: (descriptor: PaneDescriptor) => PaneState;
};

// The `as unknown as` casts are the documented cost of the uniform map: each
// view's `descriptor` prop is narrower than `PaneDescriptor`. Every component
// guards on `descriptor.kind` internally, and PaneHost only ever mounts the
// component its own descriptor's `kind` selected here.
export const paneEntries: Record<PaneDescriptor['kind'], PaneEntry> = {
  files: {
    view: FilesPane as unknown as PaneEntry['view'],
    controls: FilesPaneControls as unknown as PaneEntry['controls'],
    createState: createFilesPaneState as unknown as PaneEntry['createState']
  },
  chat: {
    view: ChatPane as unknown as PaneEntry['view'],
    controls: ChatPaneControls as unknown as PaneEntry['controls'],
    createState: createChatPaneState as unknown as PaneEntry['createState']
  },
  'chat-new': { view: ChatPane as unknown as PaneEntry['view'] },
  mail: { view: MailPane as unknown as PaneEntry['view'] }
};
```

Create the two tiny runtime state factories alongside it. They hold `$state` and therefore live in `.svelte.ts` files:

```ts
// frontend/src/lib/panes/files-pane-runtime.svelte.ts
/**
 * Per-Files-pane runtime state, created by `PaneHost` and shared between the
 * header controls and the pane body. Pure rules live in `files-pane-state.ts`;
 * this is only the reactive container.
 */
import { loadChrome, saveChrome } from './pane-memory';
import type { PaneDescriptor } from './pane-route';

export class FilesPaneState {
  kind = 'files' as const;
  treeVisible = $state(loadChrome().files.tree);
  /** Width-derived split cap, written by the pane body once it knows its width. */
  maxSplits = $state(2);
  /** Which split auto-open claimed; see `auto-open.ts`. */
  autoIndex = $state<number | null>(null);
  /** Set by the body so the header's ＋ Split can drive it. */
  addSplit: (() => void) | null = $state(null);

  toggleTree(): void {
    this.treeVisible = !this.treeVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, files: { tree: this.treeVisible } });
  }
}

export function createFilesPaneState(_descriptor: PaneDescriptor): FilesPaneState {
  return new FilesPaneState();
}
```

```ts
// frontend/src/lib/panes/chat-pane-runtime.svelte.ts
import { loadChrome, saveChrome } from './pane-memory';
import type { PaneDescriptor } from './pane-route';

export class ChatPaneState {
  kind = 'chat' as const;
  sessionsVisible = $state(loadChrome().chat.sessions);

  toggleSessions(): void {
    this.sessionsVisible = !this.sessionsVisible;
    const chrome = loadChrome();
    saveChrome({ ...chrome, chat: { sessions: this.sessionsVisible } });
  }
}

export function createChatPaneState(_descriptor: PaneDescriptor): ChatPaneState {
  return new ChatPaneState();
}
```

- [ ] **Step 2: Extend the pane context**

```ts
// frontend/src/lib/panes/context.ts — replace the type
import type { PaneDescriptor } from './pane-route';

/**
 * What a host provides to a mounted view. Views must tolerate every callback
 * being absent.
 */
export type PaneContext = {
  placement: 'primary' | 'pane';
  /** Open a file in the single Files surface, creating one if there is none. */
  openFile?: (sel: { mountKey: string; path: string }) => void;
  /** Open an arbitrary pane beside this one (subject to the cap and to fit). */
  openPane?: (d: PaneDescriptor) => void;
  /** A chat-new view created its session — host rewrites its descriptor to `chat:<id>`. */
  sessionCreated?: (id: string) => void;
  /** The view's whole subject was archived/removed — host closes this pane. */
  onArchived?: () => void;
  /**
   * ONE subject inside a multi-subject pane vanished (a Files split's file was
   * deleted). Per the spec's per-subject rule the host drops that subject and
   * keeps the pane if anything is left — never closes the pane wholesale.
   */
  onVanished?: (subject: string) => void;
};

export type { PaneDescriptor };
```

- [ ] **Step 3: Rewrite PaneHost for N panes**

Replace the markup in `frontend/src/lib/components/panes/PaneHost.svelte`. Keep the existing header comment about the unconditional primary — it is still the rule. Key points the implementation must honour:

- `PaneGroup` and the primary `Pane` stay **unconditional**; only resizers and side panes are conditional.
- Each side pane gets `order={i + 2}` so the primary stays first regardless of mount timing.
- Each side pane is wrapped in `{#key serializePaneParam(pane)}` so a genuine identity change remounts and a re-derive does not.
- Per-pane state is created once per pane via `$derived.by` over the keyed list, and `dispose()` is called on teardown if present.
- The header renders `paneTitle`, then the entry's `controls` component if any, then promote and close.

```svelte
<script lang="ts">
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import type { Snippet } from 'svelte';
  import { paneTitle, serializePaneParam, type PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import { paneEntries } from '$lib/panes/registry';
  import { loadPaneLayout, savePaneLayout } from '$lib/panes/pane-split';
  import X from '@lucide/svelte/icons/x';
  import Maximize2 from '@lucide/svelte/icons/maximize-2';

  let {
    primary,
    primaryDescriptor = null,
    panes = [],
    paneContext,
    onClose,
    onPromote
  }: {
    primary: Snippet;
    primaryDescriptor?: PaneDescriptor | null;
    panes?: PaneDescriptor[];
    paneContext: (d: PaneDescriptor, index: number) => PaneContext;
    onClose: (index: number) => void;
    onPromote: (d: PaneDescriptor) => void;
  } = $props();

  // Dedup against the primary happens in the ROUTE (dedupeSurfaces), not here:
  // the host renders what it is given so that what is on screen always matches
  // the URL exactly.
  const count = $derived(panes.length + 1);
  const layout = $derived(loadPaneLayout(count));

  function onLayoutChange(next: number[]): void {
    if (next.length === count && next.every(Number.isFinite)) savePaneLayout(count, next);
  }
</script>

<PaneGroup direction="horizontal" class="min-h-0 flex-1" {onLayoutChange}>
  <Pane order={1} defaultSize={layout?.[0]} minSize={20} class="flex min-h-0 min-w-0 flex-col">
    {@render primary()}
  </Pane>
  {#each panes as pane, i (serializePaneParam(pane))}
    {@const entry = paneEntries[pane.kind]}
    {@const state = entry.createState?.(pane)}
    <PaneResizer
      aria-label="Resize pane"
      class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
    />
    <Pane
      order={i + 2}
      defaultSize={layout?.[i + 1]}
      minSize={18}
      class="bg-paper-panel flex min-h-0 min-w-0 flex-col"
    >
      <!-- Same vertical band as the chat header, so every header rule across
           the row reads as one continuous line. size-8/-my-1.5 buttons keep
           >=32px hit targets without growing the band. -->
      <div class="border-paper-hairline flex shrink-0 items-center gap-1 border-b px-3 pt-3 pb-2">
        <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] leading-6 font-medium">
          {paneTitle(pane)}
        </span>
        {#if entry.controls && state}
          {@const Controls = entry.controls}
          <Controls {state} />
        {/if}
        <button
          type="button"
          title="Open as full view"
          aria-label="Open as full view"
          onclick={() => onPromote(pane)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <Maximize2 class="size-3.5" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          title="Close pane"
          aria-label="Close pane"
          onclick={() => onClose(i)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2"
        >
          <X class="size-3.5" strokeWidth={1.5} />
        </button>
      </div>
      {@const View = entry.view}
      <View descriptor={pane} context={paneContext(pane, i)} {state} />
    </Pane>
  {/each}
</PaneGroup>
```

- [ ] **Step 4: Delete the obsolete adapter**

```bash
git rm frontend/src/lib/components/panes/FilePaneAdapter.svelte
```

Its job — shimming `FileView` into the registry contract and owning the scroll container — moves into `FilesPane` in Task 7.

- [ ] **Step 5: Typecheck**

Run: `cd frontend && bun run check`
Expected: errors only for the not-yet-created `FilesPane`, `FilesPaneControls`, `ChatPane`, `ChatPaneControls`, `MailPane`, plus the three routes still calling deleted helpers. Do not fix routes here.

- [ ] **Step 6: Commit**

```bash
git add -A frontend/src/lib/panes/ frontend/src/lib/components/panes/
git commit -m "feat(panes): PaneHost renders N panes; registry gains the PaneEntry contract

Per-kind header controls cannot be handed upward — PaneHost renders the header
before mounting the view. The host now owns per-pane state and passes it to
both the header controls and the body, so neither parents the other.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: FilesPane — tree, splits, and the per-href flush map

**Files:**
- Create: `frontend/src/lib/components/panes/FilesPane.svelte`
- Create: `frontend/src/lib/components/panes/FilesPaneControls.svelte`
- Modify: `frontend/src/lib/components/shell/IcmTree.svelte`

**Interfaces:**
- Consumes: `openInFirst`, `openAsSecond`, `closeSplit`, `canAddSplit`, `dropVanished` (Task 3); `ancestorHrefs` (Task 3); `splitsThatFit` (Task 2); `FilesPaneState` (Task 6); `treeOpenState`, `icmStore`, `FileView`, `IcmTree`.
- Produces: `IcmTree`'s new props —
  ```svelte
  activePaths?: string[]          // replaces activePath: string
  onBeforeMutate?: (href: string) => Promise<void>   // was () => Promise<void>
  onOpenBeside?: (sel: { mountKey: string; path: string }) => void
  ```

**Context:** Everything the middle draft needed shell-level machinery for is local state here. Only **files** are valid split subjects — clicking a folder expands it and never takes a split.

- [ ] **Step 1: Widen IcmTree to multiple active rows**

In `frontend/src/lib/components/shell/IcmTree.svelte`:

- Replace the `activePath = ''` prop with `activePaths: string[] = []`. Update the doc comment: it now marks **every** open split, so with two files both rows highlight.
- Replace every `activePath === node.href` comparison (lines ~80, ~84, ~106, ~143, ~146, ~174) with `activePaths.includes(node.href)`.
- Change `onBeforeMutate?: () => Promise<void>` to `onBeforeMutate?: (href: string) => Promise<void>`, and pass it to `EntryMenu` for **every** row rather than only the active one, bound as `() => onBeforeMutate?.(node.href)`. The doc comment must say why: with two editable splits, the flush has to target the split holding that href, not "the one open page".
- Add an `onOpenBeside` prop. On file-leaf rows only, render a hover-revealed button (the same `opacity-0 group-hover/row:opacity-100 focus-visible:opacity-100` pattern the chat list's archive button uses) that calls `onOpenBeside({ mountKey: node.mountKey, path: node.path })` and stops propagation. Label it "Open beside".
- Forward `activePaths`, `onBeforeMutate` and `onOpenBeside` to the recursive `<IcmTree>` call.

- [ ] **Step 2: Write FilesPane**

```svelte
<!-- frontend/src/lib/components/panes/FilesPane.svelte -->
<script lang="ts">
  /**
   * The file browser as ONE pane: an optional 240px ICM tree plus one or two
   * file splits. From the outside it is a single pane, which is the whole point
   * — nothing outside this component can observe that the tree relates to the
   * splits, so there is no cross-pane sync to arrange.
   *
   * Owns the split -> FileView ref map that `onBeforeMutate(href)` dispatches
   * over: with two editable splits, a rename must flush the split holding that
   * file and not its sibling.
   */
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import FileView from '$lib/components/views/FileView.svelte';
  import IcmTree from '$lib/components/shell/IcmTree.svelte';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { treeOpenState } from '$lib/stores/tree-state.svelte';
  import { icmToNav, knowledgeHref } from '$lib/shell/nav';
  import { ancestorHrefs } from '$lib/shell/reveal-path';
  import { splitsThatFit } from '$lib/shell/pane-fit';
  import { loadFilesSplit, saveFilesSplit } from '$lib/panes/pane-split';
  import { closeSplit, openAsSecond, openInFirst } from '$lib/panes/files-pane-state';
  import type { FilesPaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let {
    descriptor,
    context,
    state
  }: { descriptor: FilesPaneDescriptor; context: PaneContext; state: FilesPaneState } = $props();

  let paneWidth = $state(0);
  const maxSplits = $derived(splitsThatFit(paneWidth, state.treeVisible));

  // Publish the width-derived cap and the add-split action so the header's
  // controls (rendered by PaneHost, not by this component) can drive them.
  $effect(() => {
    state.maxSplits = maxSplits;
  });

  const treeNav = $derived(
    icmToNav(icmStore.groups.find((g) => g.mount === descriptor.mountKey)?.tree ?? [])
  );
  const activePaths = $derived(
    descriptor.paths.map((p) => knowledgeHref(descriptor.mountKey, p))
  );

  // Reveal the newest split's ancestors and scroll it into view. Only the
  // newest: scrolling for both open files would fight itself.
  let revealed: string | null = null;
  $effect(() => {
    const newest = descriptor.paths.at(-1);
    if (!newest || newest === revealed) return;
    revealed = newest;
    for (const href of ancestorHrefs(descriptor.mountKey, newest)) treeOpenState.open(href);
    const target = knowledgeHref(descriptor.mountKey, newest);
    queueMicrotask(() =>
      document.querySelector(`[data-tree-href="${CSS.escape(target)}"]`)?.scrollIntoView({
        block: 'nearest'
      })
    );
  });

  // Split -> FileView ref map, keyed by href so a rename flushes the right one.
  // `flushPending` is FileView's existing exported method (FileView.svelte:56),
  // the same one the Knowledge route calls through its single `fileViewRef`.
  const views: Record<string, { flushPending?: () => Promise<void> }> = {};

  async function beforeMutate(href: string): Promise<void> {
    await views[href]?.flushPending?.();
  }

  function setPaths(paths: string[]): void {
    context.openPane?.({ ...descriptor, paths });
  }
</script>

<div bind:clientWidth={paneWidth} class="flex min-h-0 min-w-0 flex-1">
  {#if state.treeVisible}
    <div class="border-paper-hairline w-[240px] shrink-0 overflow-y-auto border-r">
      <IcmTree
        nodes={treeNav}
        {activePaths}
        onBeforeMutate={beforeMutate}
        onSelect={(sel) => setPaths(openInFirst(descriptor.paths, sel.path, maxSplits))}
        onOpenBeside={(sel) => setPaths(openAsSecond(descriptor.paths, sel.path, maxSplits))}
      />
    </div>
  {/if}

  {#if descriptor.paths.length === 0}
    <p class="text-ink-meta m-auto px-6 text-[12.5px]">Pick a file to read it.</p>
  {:else}
    <PaneGroup
      direction="horizontal"
      class="min-h-0 flex-1"
      onLayoutChange={(l) => l.length === 2 && Number.isFinite(l[0]) && saveFilesSplit(l[0])}
    >
      {#each descriptor.paths as path, i (path)}
        {#if i > 0}
          <PaneResizer
            aria-label="Resize split"
            class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
          />
        {/if}
        <Pane
          order={i + 1}
          defaultSize={i === 0 && descriptor.paths.length === 2 ? loadFilesSplit() : undefined}
          minSize={20}
          class="flex min-h-0 min-w-0 flex-col"
        >
          {#if descriptor.paths.length > 1}
            <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
              <span class="text-ink-meta min-w-0 flex-1 truncate font-mono text-[11px]">{path}</span>
              <button
                type="button"
                aria-label={`Close ${path}`}
                onclick={() => setPaths(closeSplit(descriptor.paths, i))}
                class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-8 items-center justify-center rounded-md"
              >
                ✕
              </button>
            </div>
          {/if}
          <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
            <FileView
              bind:this={views[knowledgeHref(descriptor.mountKey, path)]}
              mountKey={descriptor.mountKey}
              {path}
              onVanished={() => context.onVanished?.(path)}
            />
          </div>
        </Pane>
      {/each}
    </PaneGroup>
  {/if}
</div>
```

Add `data-tree-href={node.href}` to `IcmTree`'s leaf row anchors so the scroll-into-view query above resolves.

- [ ] **Step 3: Write FilesPaneControls**

```svelte
<!-- frontend/src/lib/components/panes/FilesPaneControls.svelte -->
<script lang="ts">
  /**
   * The Files pane's own header controls, rendered by PaneHost INSIDE the
   * shared pane header — so the pane has one header, one close button, and
   * per-kind extras. State is created by the host and shared with the body;
   * neither component parents the other.
   */
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import Columns2 from '@lucide/svelte/icons/columns-2';
  import type { FilesPaneState } from '$lib/panes/files-pane-runtime.svelte';

  let { state }: { state: FilesPaneState } = $props();
</script>

<button
  type="button"
  title={state.treeVisible ? 'Hide the file tree' : 'Show the file tree'}
  aria-label={state.treeVisible ? 'Hide the file tree' : 'Show the file tree'}
  aria-pressed={state.treeVisible}
  onclick={() => state.toggleTree()}
  class="hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 {state.treeVisible
    ? 'text-ink-heading'
    : 'text-ink-meta hover:text-ink-heading'}"
>
  <PanelLeft class="size-3.5" strokeWidth={1.5} />
</button>
<button
  type="button"
  title={state.maxSplits < 2 ? 'Not enough width for a second file' : 'Open a second file'}
  aria-label="Open a second file"
  disabled={state.maxSplits < 2 || !state.addSplit}
  onclick={() => state.addSplit?.()}
  class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 disabled:opacity-40 disabled:hover:bg-transparent"
>
  <Columns2 class="size-3.5" strokeWidth={1.5} />
</button>
```

- [ ] **Step 4: Typecheck**

Run: `cd frontend && bun run check`
Expected: remaining errors are only the not-yet-created `ChatPane`/`ChatPaneControls`/`MailPane` and the routes.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/panes/FilesPane.svelte \
        frontend/src/lib/components/panes/FilesPaneControls.svelte \
        frontend/src/lib/components/shell/IcmTree.svelte
git commit -m "feat(panes): FilesPane — tree plus up to two splits, per-href flush map

IcmTree marks every open split and dispatches onBeforeMutate by href, so a
rename flushes the split holding that file rather than 'the one open page'.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: MailPane and ChatPane

**Files:**
- Create: `frontend/src/lib/components/panes/MailPane.svelte`
- Create: `frontend/src/lib/components/panes/ChatPane.svelte`
- Create: `frontend/src/lib/components/panes/ChatPaneControls.svelte`
- Modify: `frontend/src/routes/mail/+page.svelte`

**Interfaces:**
- Consumes: `ChatPaneState` (Task 6); `MessageList`, `mailStore`; `ChatView`, `sessionsListStore`, `groupAllSessions`.
- Produces:
  ```svelte
  <MailPane
    account={string}
    selectedId={string | null}
    onSelect={(account: string, msgId: string) => void}
    onAccountChange={(account: string) => void}
    listVisible={boolean}
  />
  ```

**Context — Mail scope boundary:** `/mail` owns far more than a list and a reader: account-qualified selection with race suppression (`routes/mail/+page.svelte:118-163`), search with debounce (`183-244`), the drafts panel (`?drafts=1`), compose (`?compose=`) and the setup modal (`?setup=1`). A **Mail pane is the read surface only**; those modes stay route-only. The route composes the same `MailPane` plus its own modes, so list-and-reader has one implementation.

**Context — navigation adapter:** `MessageList` renders each row as an anchor to `messageHref(account, msgId)` (`MessageList.svelte:69`). A pane must not follow that — clicking a row inside a pane rewrites the pane's descriptor. So `MessageList` gains an optional `onSelect` prop; when set, rows call it instead of navigating (the same shape `IcmTree`'s `onSelect` already uses for popover pickers). When absent, the existing href behaviour is unchanged.

- [ ] **Step 1: Give MessageList a selection callback**

In `frontend/src/lib/components/mail/MessageList.svelte`, add:

```ts
onSelect?: (account: string, msgId: string) => void;
```

When `onSelect` is set, render each row as a `<button type="button">` carrying the same classes and calling `onSelect(account, message.msgId)`; when absent, keep the existing `<a href={messageHref(account, message.msgId)}>`. Document why: a row inside a pane must rewrite that pane's descriptor rather than navigate the whole app to `/mail`.

- [ ] **Step 2: Write MailPane**

```svelte
<!-- frontend/src/lib/components/panes/MailPane.svelte -->
<script lang="ts">
  /**
   * The mail READ SURFACE — account-scoped message list plus the open message.
   * Deliberately not the whole route: compose, drafts and setup are
   * full-screen tasks, not things you glance at beside a transcript, and they
   * stay in `/mail`.
   *
   * Selection arrives as callbacks rather than hrefs so one implementation
   * serves both hosts: the route passes a `goto`, a pane passes a descriptor
   * rewrite. Same shape `PaneContext.openFile` already uses.
   */
  import MessageList from '$lib/components/mail/MessageList.svelte';
  import { mailStore } from '$lib/stores/mail.svelte';
  import type { PaneContext } from '$lib/panes/context';
  import type { MailPaneDescriptor } from '$lib/panes/pane-route';

  let {
    descriptor,
    context
  }: { descriptor: MailPaneDescriptor; context: PaneContext } = $props();

  // Availability is only ever asserted from LOADED data: `mailStore.accounts`
  // starts empty, so "no account" must not be concluded before a fetch.
  const known = $derived(mailStore.statusLoaded);
  const account = $derived(descriptor.account);

  $effect(() => {
    if (account) void mailStore.selectAccount(account);
  });

  // `selectAccount` and `select` are MailStore's existing methods
  // (mail.svelte.ts:644, 809) — there is no `openMessage`.
  $effect(() => {
    if (descriptor.msgId) void mailStore.select(descriptor.msgId);
  });
</script>

<div class="flex min-h-0 min-w-0 flex-1">
  <div class="border-paper-hairline w-[260px] shrink-0 overflow-y-auto border-r">
    {#if known && mailStore.accounts.length === 0}
      <p class="text-ink-meta px-3.5 py-3 text-[12.5px]">
        No mail account yet. Add one in Sources.
      </p>
    {:else}
      <MessageList
        {account}
        messages={mailStore.messages}
        selectedId={descriptor.msgId}
        onSelect={(acct, msgId) => context.openPane?.({ ...descriptor, account: acct, msgId })}
      />
    {/if}
  </div>
  <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
    {#if !descriptor.msgId}
      <p class="text-ink-meta text-[12.5px]">Pick a message to read it.</p>
    {:else if mailStore.selected}
      <!-- Reuse the route's existing read-pane markup verbatim; move it here
           and have the route render this component in its place. -->
    {/if}
  </div>
</div>
```

Move the route's read-pane markup (`routes/mail/+page.svelte:479-528`'s message body branch) into the placeholder above, and add a `statusLoaded` boolean to `MailStore`, set to `true` at the end of `refreshStatus()`. Then have `/mail` render `<MailPane>` for its list+reader while keeping its compose, drafts and setup branches around it.

- [ ] **Step 3: Write ChatPane and ChatPaneControls**

`ChatPane` wraps `ChatView` with the all-sessions navigator lifted out of `routes/chat/+page.svelte:259-346` (the `allSessions` snippet, `groupAllSessions`, the include-scheduled checkbox, the per-row archive button, `sessionTitle`, `relativeTime`). `ChatView` itself is untouched — it is documented as never reading `page.url` (`ChatView.svelte:8`) precisely so it can be mounted in a pane, and that must stay true.

```svelte
<!-- frontend/src/lib/components/panes/ChatPane.svelte -->
<script lang="ts">
  /**
   * A chat surface: the optional all-sessions navigator plus the transcript.
   * The navigator is the route's old `?all=1` column, moved here so a chat in
   * a PANE can have one too. `ChatView` still never reads `page.url` — the
   * descriptor and the callbacks are its whole world.
   */
  import ChatView from '$lib/components/views/ChatView.svelte';
  import { sessionsListStore } from '$lib/stores/sessions-list.svelte';
  import { groupAllSessions } from '$lib/components/shell/icm-projects';
  import type { PaneContext } from '$lib/panes/context';
  import type { ChatNewPaneDescriptor, ChatPaneDescriptor } from '$lib/panes/pane-route';
  import type { ChatPaneState } from '$lib/panes/chat-pane-runtime.svelte';

  let {
    descriptor,
    context,
    state
  }: {
    descriptor: ChatPaneDescriptor | ChatNewPaneDescriptor;
    context: PaneContext;
    state?: ChatPaneState;
  } = $props();

  const groups = $derived(groupAllSessions(sessionsListStore.visibleSessions));
  const selectedId = $derived(descriptor.kind === 'chat' ? descriptor.sessionId : null);
</script>

<div class="flex min-h-0 min-w-0 flex-1">
  {#if state?.sessionsVisible}
    <div class="border-paper-hairline w-[240px] shrink-0 overflow-y-auto border-r">
      <!-- Move the route's `allSessions` list body here verbatim, replacing
           each row's <a href={sessionHref(id)}> with a button that calls
           context.openPane?.({ kind: 'chat', sessionId: id }). -->
    </div>
  {/if}
  <ChatView {descriptor} {context} />
</div>
```

```svelte
<!-- frontend/src/lib/components/panes/ChatPaneControls.svelte -->
<script lang="ts">
  import PanelLeft from '@lucide/svelte/icons/panel-left';
  import type { ChatPaneState } from '$lib/panes/chat-pane-runtime.svelte';

  let { state }: { state: ChatPaneState } = $props();
</script>

<button
  type="button"
  title={state.sessionsVisible ? 'Hide sessions' : 'Show sessions'}
  aria-label={state.sessionsVisible ? 'Hide sessions' : 'Show sessions'}
  aria-pressed={state.sessionsVisible}
  onclick={() => state.toggleSessions()}
  class="hover:bg-paper-pill focus-visible:ring-ring/50 -my-1.5 flex size-8 items-center justify-center rounded-md transition-colors outline-none focus-visible:ring-2 {state.sessionsVisible
    ? 'text-ink-heading'
    : 'text-ink-meta hover:text-ink-heading'}"
>
  <PanelLeft class="size-3.5" strokeWidth={1.5} />
</button>
```

- [ ] **Step 4: Typecheck**

Run: `cd frontend && bun run check`
Expected: remaining errors only in `routes/chat` and `routes/knowledge`, fixed in Task 9.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/panes/ frontend/src/lib/components/mail/MessageList.svelte \
        frontend/src/lib/stores/mail.svelte.ts frontend/src/routes/mail/+page.svelte
git commit -m "feat(panes): MailPane read surface and ChatPane sessions navigator

MessageList takes an optional onSelect so a row inside a pane rewrites that
pane's descriptor instead of navigating the app to /mail. Compose, drafts and
setup stay route-only.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: AppShell restructure, ContentBar, and all three route conversions

**Files:**
- Create: `frontend/src/lib/components/shell/ContentBar.svelte`
- Create: `frontend/src/lib/shell/content-bar.ts`
- Create: `frontend/src/lib/shell/content-bar.test.ts`
- Modify: `frontend/src/lib/components/shell/AppShell.svelte`, `AppFrame.svelte`, `index.ts`
- Modify: `frontend/src/routes/chat/+page.svelte`, `frontend/src/routes/mail/+page.svelte`, `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte`
- Modify: `frontend/src/lib/components/agent/SessionHeader.svelte`, `frontend/src/lib/components/views/ChatView.svelte`

**Interfaces:**
- Consumes: everything from Tasks 1–8.
- Produces:
  ```ts
  export type MenuItem = {
    kind: 'files' | 'chat' | 'mail';
    label: string;
    descriptor: PaneDescriptor | null;   // null when unavailable
    disabledReason: string | null;
  };
  export function menuItems(input: {
    icmParam: string | null;
    enabledMountKeys: string[];
    mailAccounts: string[];
    mailStatusLoaded: boolean;
    openKinds: string[];
  }): MenuItem[];
  ```

**Context:** This task must ship as one change. The routes depend on `AppShell`'s `list` prop until they are converted, so removing it first would leave the tree broken between steps.

**Why `resolveIcmSelection`, not `resolveActiveMountKey`:** the latter bottoms out at `?icm=` (`lib/shell/icm-route.ts:73`) and so returns `null` on Today or Tasks, which would disable Files and Chat despite a healthy workspace. `resolveIcmSelection(icmParam, enabledMountKeys)` is the helper `/chat`'s own `primaryMountKey()` already uses; callers filter `m.enabled && !m.degraded` before passing the keys.

**Why Mail stays enabled while status is unknown:** `mailStore.accounts` starts empty and only fills on `refreshStatus()`, which today only `/mail` calls on mount. Opening the menu beside a chat would otherwise report "No mail account yet" before anything was fetched. `AppShell` kicks a one-time `refreshStatus()`, and availability is only ever asserted from loaded data.

- [ ] **Step 1: Write the failing menu tests**

```ts
// frontend/src/lib/shell/content-bar.test.ts
import { describe, expect, it } from 'vitest';
import { menuItems } from './content-bar';

const base = {
  icmParam: null,
  enabledMountKeys: ['life', 'valea'],
  mailAccounts: ['mara@example.com'],
  mailStatusLoaded: true,
  openKinds: [] as string[]
};

function item(kind: string, over: Partial<typeof base> = {}) {
  return menuItems({ ...base, ...over }).find((i) => i.kind === kind)!;
}

describe('menuItems', () => {
  it('finds a mount with no ?icm= at all — the Today/Tasks case', () => {
    expect(item('files').descriptor).toEqual({ kind: 'files', mountKey: 'life', paths: [] });
    expect(item('chat').descriptor).toEqual({ kind: 'chat-new', mountKey: 'life' });
  });

  it('honours an explicit ?icm=', () => {
    expect(item('files', { icmParam: 'valea' }).descriptor).toEqual({
      kind: 'files',
      mountKey: 'valea',
      paths: []
    });
  });

  it('disables Files and Chat when no mount is enabled', () => {
    const none = { enabledMountKeys: [] };
    expect(item('files', none).descriptor).toBeNull();
    expect(item('files', none).disabledReason).toBe('No ICM is mounted yet');
    expect(item('chat', none).descriptor).toBeNull();
  });

  it('opens Mail on the first configured account', () => {
    expect(item('mail').descriptor).toEqual({
      kind: 'mail',
      account: 'mara@example.com',
      msgId: null
    });
  });

  it('stays enabled while mail status is unknown', () => {
    const unknown = { mailAccounts: [], mailStatusLoaded: false };
    expect(item('mail', unknown).disabledReason).toBeNull();
  });

  it('disables Mail only once a loaded status shows no account', () => {
    const none = { mailAccounts: [], mailStatusLoaded: true };
    expect(item('mail', none).descriptor).toBeNull();
    expect(item('mail', none).disabledReason).toBe('No mail account yet');
  });

  it('marks a kind that is already open as inert', () => {
    expect(item('chat', { openKinds: ['chat'] }).disabledReason).toBe('Already open');
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && bun run test src/lib/shell/content-bar.test.ts`
Expected: FAIL — `content-bar.ts` does not exist.

- [ ] **Step 3: Implement content-bar.ts**

```ts
// frontend/src/lib/shell/content-bar.ts
/**
 * What the ＋ Pane menu offers. Every item must name a CONCRETE subject — no
 * descriptor kind accepts "empty" — so this resolves a mount and an account
 * up front rather than opening a picker.
 *
 * Availability is only ever asserted from LOADED data: an unknown mail status
 * leaves the item enabled and lets the Mail pane show its own no-account empty
 * state, which is both truthful and recoverable.
 */
import { resolveIcmSelection } from './icm-route';
import type { PaneDescriptor } from '$lib/panes/pane-route';

export type MenuItem = {
  kind: 'files' | 'chat' | 'mail';
  label: string;
  descriptor: PaneDescriptor | null;
  disabledReason: string | null;
};

export function menuItems(input: {
  icmParam: string | null;
  enabledMountKeys: string[];
  mailAccounts: string[];
  mailStatusLoaded: boolean;
  openKinds: string[];
}): MenuItem[] {
  const mount = resolveIcmSelection(input.icmParam, input.enabledMountKeys);
  const account = input.mailAccounts[0] ?? null;
  const mailAbsent = input.mailStatusLoaded && input.mailAccounts.length === 0;

  const items: MenuItem[] = [
    {
      kind: 'files',
      label: 'Files',
      descriptor: mount ? { kind: 'files', mountKey: mount, paths: [] } : null,
      disabledReason: mount ? null : 'No ICM is mounted yet'
    },
    {
      kind: 'chat',
      label: 'Chat',
      descriptor: mount ? { kind: 'chat-new', mountKey: mount } : null,
      disabledReason: mount ? null : 'No ICM is mounted yet'
    },
    {
      kind: 'mail',
      label: 'Mail',
      descriptor: mailAbsent || !account ? null : { kind: 'mail', account, msgId: null },
      disabledReason: mailAbsent ? 'No mail account yet' : null
    }
  ];

  // A kind already on screen is shown checked and inert rather than hidden.
  return items.map((i) =>
    input.openKinds.includes(i.kind === 'chat' ? 'chat-new' : i.kind) ||
    input.openKinds.includes(i.kind)
      ? { ...i, descriptor: null, disabledReason: 'Already open' }
      : i
  );
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && bun run test src/lib/shell/content-bar.test.ts`
Expected: PASS.

- [ ] **Step 5: Write ContentBar**

`frontend/src/lib/components/shell/ContentBar.svelte`. Props: `items: MenuItem[]`, `onOpen: (d: PaneDescriptor) => void`, `canAddPane: boolean`, `navVisible: boolean`, `onToggleNav: () => void`. Styling is furniture, not feature — `bg-paper-sidebar`, `border-t border-paper-hairline`, `text-ink-meta` inactive and `text-ink-heading` active, **no accent colour**, ~28px band, `＋ Pane` right-aligned opening a `bits-ui` `DropdownMenu` whose disabled items render their `disabledReason`. Nav toggle at the far left. Every button carries an `aria-label`; hit targets ≥ 32px.

- [ ] **Step 6: Restructure AppShell and AppFrame**

`AppShell` becomes nav plus a content column that holds the pane row and the bar. The nav is a full-height anchor, so the bar sits **beside** it, never under it:

```svelte
<div class="bg-paper-surface text-ink-body flex h-screen">
  {#if navVisible}
    <aside class="border-paper-hairline bg-paper-sidebar w-[236px] shrink-0 border-r">
      {@render sidebar()}
    </aside>
  {/if}
  <div class="flex min-w-0 flex-1 flex-col">
    <div class="flex min-h-0 flex-1">{@render main()}</div>
    <ContentBar {items} {onOpen} {canAddPane} {navVisible} {onToggleNav} />
  </div>
</div>
```

Delete the `list` and `rail` props from both `AppShell` and `AppFrame`. `rail` is already dead code — `AppFrame` forwards it and no route passes it. Add a one-time `void mailStore.refreshStatus()` in `AppFrame`'s `onMount` beside the existing `icmStore.refetch()`, so the Mail menu item has loaded data to reason about.

Routes that are not pane hosts keep passing a plain `main` snippet and gain the bar with no per-route work — there is **one path, not two**.

- [ ] **Step 7: Convert the three routes**

For each of `/chat`, `/mail`, `/knowledge` and `/knowledge/[...path]`:

- Derive `panes = dedupeSurfaces(primaryDescriptor, parsePanes(page.url.searchParams))`.
- Render `<PaneHost {primary} {primaryDescriptor} {panes} … />`.
- `onClose={(i) => goto(withPanes(page.url, panes.filter((_, j) => j !== i)), { keepFocus: true, noScroll: true })}`.
- `onPromote={(d) => goto(promoteTarget(d, page.url, panes))}`.
- `paneContext={(d, i) => ({ … })}` supplying `openPane` (rewrites pane `i`), `openFile` (routes into the Files surface), `onArchived` (closes pane `i` with `replaceState`) and `onVanished` (drops one subject, closing the pane only when nothing is left).
- Replace every `withPaneParam`/`hrefWithPane`/`paneLinkSearch` call with `withPanes`.

On `/chat`, delete the `allSessions` snippet and its helpers — they now live in `ChatPane` — and read `chatNavigatorFromUrl(page.url)` for the primary's navigator. On `/knowledge/[...path]`, delete the inlined ancestor-reveal loop in favour of `ancestorHrefs`, and read `?split=` into the primary's second file.

Finally, delete the popover file tree from `SessionHeader.svelte` (its `Popover.Root` wrapping `IcmTree`, lines ~93-116) and the `treeRequestedFor` root-load effect from `ChatView.svelte` (~lines 219-240) that fed it. The tree is a pane now.

- [ ] **Step 8: Typecheck and run the full suite**

Run: `cd frontend && bun run check && bun run test`
Expected: both clean. Zero svelte-check errors.

- [ ] **Step 9: Verify in the browser**

Start the dev server via the preview tooling (never `bash`), then confirm:
1. `/chat` — open a file from a tool chip; it lands in a Files pane with the tree visible.
2. `＋ Pane → Files`, then click a file: it opens in the first split. Hover another row, use "Open beside": two files, both highlighted in the tree.
3. Close one split: its sibling survives.
4. `/mail` — `＋ Pane → Chat` gives a chat beside a message.
5. Promote (⤢) a pane: the remaining pane survives and the URL carries it.
6. Reload: the composition is restored from the URL.
7. Narrow the window below ~1150px, then open `＋ Pane`: the second entry is disabled with a reason. Nothing disappears on resize alone.

- [ ] **Step 10: Commit**

```bash
git add -A frontend/src
git commit -m "feat(panes): pane row shell, content bar, and route conversions

AppShell becomes nav plus a content column holding the pane row and the bar,
so the nav is a full-height anchor with the bar beside it rather than under it.
list and rail props are gone; rail was already dead code. Chat, Mail and
Knowledge all render through PaneHost, and the SessionHeader popover tree
retires in favour of the Files pane.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 10: Memory restore and assistant auto-open

**Files:**
- Modify: `frontend/src/routes/chat/+page.svelte`, `frontend/src/routes/mail/+page.svelte`, `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte`
- Modify: `frontend/src/lib/components/panes/FilesPane.svelte`

**Interfaces:**
- Consumes: `loadPanes`, `savePanes`, `routeKeyFor` (Task 4); `truncateToFit` (Task 2); `autoOpen`, `clearAuto` (Task 4).

**Context:** Memory applies **only when the URL names no panes**, so a link shared between two people is never rewritten by the recipient's habits. Restore truncates to what fits while memory keeps the full list, so a pane returns on a wider window next time.

- [ ] **Step 1: Wire restore-on-entry**

In each pane-host route, add one effect:

```ts
// Restore the last composition ONLY when the URL names none: a URL carrying
// `pane` always wins, so a shared link survives contact with the recipient's
// own habits. replaceState so Back does not step through the bare URL.
let restored = false;
$effect(() => {
  if (restored) return;
  restored = true;
  if (page.url.searchParams.has('pane')) return;
  const key = routeKeyFor(page.url.pathname);
  if (!key) return;
  const remembered = truncateToFit(loadPanes(key), window.innerWidth, true);
  const fitted = dedupeSurfaces(primaryDescriptor, remembered);
  if (fitted.length === 0) return;
  void goto(withPanes(page.url, fitted), { replaceState: true, keepFocus: true, noScroll: true });
});
```

And one save effect:

```ts
$effect(() => {
  const key = routeKeyFor(page.url.pathname);
  if (key) savePanes(key, panes);
});
```

- [ ] **Step 2: Wire auto-open into FilesPane**

Add to `FilesPane.svelte`, and have `context.openFile` on each route route into the single Files surface:

```ts
// The assistant recycles the split it created; a file the USER opened is never
// evicted. A user-initiated open into a split releases the claim on it.
export function receiveAutoFile(path: string): void {
  const next = autoOpen(descriptor.paths, state.autoIndex, path, maxSplits);
  state.autoIndex = next.autoIndex;
  if (next.paths !== descriptor.paths) setPaths(next.paths);
}
```

In the tree-click and open-beside handlers, call `state.autoIndex = clearAuto(state.autoIndex, targetIndex)` before `setPaths`.

Also publish `state.addSplit` so the header's `＋ Split` works:

```ts
$effect(() => {
  state.addSplit = () => {
    const first = treeNav.find((n) => n.isFile);
    if (first) setPaths(openAsSecond(descriptor.paths, first.path, maxSplits));
  };
  return () => { state.addSplit = null; };
});
```

- [ ] **Step 3: Typecheck and test**

Run: `cd frontend && bun run check && bun run test`
Expected: both clean.

- [ ] **Step 4: Verify in the browser**

1. On `/chat`, open a Files pane with a file. Navigate to `/mail`, then back to `/chat` — the composition returns.
2. Open a file yourself in split 1. Ask the assistant to read a different file: it takes split 2, then keeps recycling split 2 on subsequent reads while your file stays in split 1.
3. Fill both splits yourself: assistant reads no longer move anything.
4. Paste a URL with `?pane=` into a fresh window — it wins over memory.

- [ ] **Step 5: Commit**

```bash
git add -A frontend/src
git commit -m "feat(panes): restore compositions per route and land assistant files safely

Memory applies only when the URL names no panes, so a shared link is never
rewritten by the recipient's habits. Auto-open recycles the split it created
and never evicts a file the user placed.

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| Pane kinds, wire forms, mail account identity | 1 |
| Repeated `?pane=`, cap, `dedupeSurfaces`, `?all=1` alias | 1 |
| Width behaviour, per-count layouts | 2 |
| Files pane split rules, tree-click target, reveal | 3 |
| Auto-open three-step rule | 4, 10 |
| Memory: route keys, versioning, pruning | 4, 10 |
| Promotion merge rules | 5 |
| `PaneEntry` contract, host-owned state, N panes | 6 |
| `FilesPane`, `IcmTree` multi-mark, per-href flush | 7 |
| Mail scope boundary, navigation adapter, Chat navigator | 8 |
| `AppShell` restructure, `ContentBar`, menu subjects | 9 |
| Retirements (`SessionHeader` tree, `list`/`rail`, `FilePaneAdapter`) | 6, 9 |
| Per-subject stale handling | 6 (context), 7 (`onVanished`), 9 (route handler) |

**Known gap carried from the spec:** *nav collapse* is an unresolved open item. This plan implements it (`navVisible` in `AppShell`, toggle at the bar's far left, default on) because the spec proposes keeping it. If Daniel cuts it, delete the `navVisible` prop and the toggle from Task 9 Steps 5–6; nothing else depends on it.

**Type consistency check:** `PaneDescriptor` kinds are `files` / `chat` / `chat-new` / `mail` throughout. `paths: string[]` (never `path`) on Files everywhere after Task 1. `maxSplits` is the parameter name in `files-pane-state.ts`, `auto-open.ts` and `FilesPaneState` alike. `onBeforeMutate(href: string)` matches between `IcmTree` (Task 7 Step 1) and `FilesPane.beforeMutate` (Step 2). `promoteTarget(promoted, url, panes)` has the same signature in Task 5 and its Task 9 call site. `menuItems` input keys match between `content-bar.ts` and its test.

---

## Execution Handoff

**Plan complete and saved to `docs/superpowers/plans/2026-07-31-composable-views.md`. Two execution options:**

**1. Subagent-Driven (recommended)** — I dispatch a fresh subagent per task, review between tasks, fast iteration

**2. Inline Execution** — Execute tasks in this session using executing-plans, batch execution with checkpoints

**Which approach?**
