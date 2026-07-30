# Message File Links Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Backticked file paths and URLs in agent chat prose become clickable (file pane / external link), and a live turn whose final message names exactly one existing file auto-opens it in the pane.

**Architecture:** Pure detection helpers join `agent-markdown.ts`; the codespan branch of the token-tree renderer gains link/button variants with an `onOpenFile` prop threaded down from `Transcript`; a small pure module decides the auto-open candidate over `store.items`, and a thin `ChatView` effect wires it to the existing `icmPathsExist` RPC and `openToolFile`. No backend changes.

**Tech Stack:** Svelte 5 (runes), TypeScript, marked token tree, Vitest. Spec: `docs/superpowers/specs/2026-07-30-message-file-links-design.md`.

## Global Constraints

- `{@html}` is FORBIDDEN in the `agent/` component family — every text leaf reaches the DOM through plain Svelte interpolation.
- Untrusted agent strings flow ONLY into existing validated sinks: `openToolFile` → `?pane=` codec, `safeLinkHref`-vetted hrefs, `icmPathsExist`.
- Frontend has NO prettier — never run it; backend files are auto-formatted by the repo's mix-format hook.
- Gates for every task: `cd frontend && npm run check` reports 0 errors, `npx vitest run` fully green.
- Commit messages end with `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`.

---

### Task 1: Detection helpers `codespanFilePath` / `messageFilePaths`

**Files:**
- Modify: `frontend/src/lib/markdown/agent-markdown.ts`
- Test: `frontend/src/lib/markdown/agent-markdown.test.ts`

**Interfaces:**
- Consumes: existing `lexAgentMarkdown`, `unescapeMarked`, `Token` from the same module.
- Produces: `codespanFilePath(text: string): string | undefined` (input: DECODED codespan text; returns the openable relPath, `:NN` line suffix stripped) and `messageFilePaths(text: string): string[]` (input: full raw message markdown; returns distinct candidate relPaths). Tasks 2 and 3 import both by these exact names.

- [ ] **Step 1: Write the failing tests**

Append to `frontend/src/lib/markdown/agent-markdown.test.ts` (add `codespanFilePath, messageFilePaths` to the existing import from `'./agent-markdown'`):

```ts
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
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && npx vitest run src/lib/markdown/agent-markdown.test.ts`
Expected: FAIL — `codespanFilePath` / `messageFilePaths` not exported.

- [ ] **Step 3: Implement the helpers**

Append to `frontend/src/lib/markdown/agent-markdown.ts`:

```ts
// Basename must END in a letter-led extension, and the match must not start
// at index 0 (bare ".md" or ".gitignore" is not a stem + extension —
// documented accepted miss).
const EXTENSION_RE = /\.[A-Za-z][A-Za-z0-9]{0,7}$/;

/**
 * The openable ICM-relative path of a codespan, or undefined. Input is the
 * DECODED codespan text (marked pre-escapes codespans — callers pass it
 * through `unescapeMarked` first, so what opens is exactly what displays).
 * One trailing `:NN` line suffix is stripped (`CONTEXT.md:22`). Anything
 * absolute, traversal-y, directory-like, scheme-ish, or not ending in a
 * letter-led extension is rejected; spaces are allowed only when a `/` is
 * present (`clients/Mara Lindt/notes.md`), so a backticked sentence never
 * qualifies. The returned string is untrusted agent output — callers hand
 * it ONLY to the `?pane=` codec / backend-validated APIs.
 */
export function codespanFilePath(text: string): string | undefined {
  if (!text || text.length > 256) return undefined;
  const stripped = text.replace(/:\d+$/, '');
  if (!stripped || stripped.includes(':')) return undefined; // scheme, drive, second :NN
  if (stripped.startsWith('/') || stripped.startsWith('~')) return undefined;
  if (stripped.endsWith('/')) return undefined;
  if (/[`()\\]/.test(stripped)) return undefined;
  for (let i = 0; i < stripped.length; i++) {
    const code = stripped.charCodeAt(i);
    if (code < 32 || code === 127) return undefined; // control chars incl. tab/newline
  }
  if (stripped.includes(' ') && !stripped.includes('/')) return undefined;
  const segments = stripped.split('/');
  if (segments.some((seg) => seg === '' || seg === '.' || seg === '..')) return undefined;
  const basename = segments[segments.length - 1];
  const ext = EXTENSION_RE.exec(basename);
  if (!ext || ext.index === 0) return undefined;
  return stripped;
}

/**
 * Distinct `codespanFilePath` hits across a whole agent message — the
 * auto-open candidate set. Walks the lexed token tree through every inline
 * container (emphasis, links, list items, table cells) but never descends
 * into fenced `code` blocks; codespan text is decoded before detection.
 */
export function messageFilePaths(text: string): string[] {
  if (!text) return [];
  const seen = new Set<string>();
  type Walkable = Token & {
    text?: string;
    tokens?: Token[];
    items?: Array<{ tokens?: Token[] }>;
    header?: Array<{ tokens?: Token[] }>;
    rows?: Array<Array<{ tokens?: Token[] }>>;
  };
  const walk = (tokens: Token[]): void => {
    for (const token of tokens as Walkable[]) {
      if (token.type === 'codespan') {
        const path = codespanFilePath(unescapeMarked(token.text ?? ''));
        if (path) seen.add(path);
        continue;
      }
      if (token.type === 'code') continue;
      if (token.tokens) walk(token.tokens);
      if (token.items) for (const item of token.items) walk(item.tokens ?? []);
      if (token.header) for (const cell of token.header) walk(cell.tokens ?? []);
      if (token.rows) for (const row of token.rows) for (const cell of row) walk(cell.tokens ?? []);
    }
  };
  walk(lexAgentMarkdown(text));
  return [...seen];
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && npx vitest run src/lib/markdown/agent-markdown.test.ts`
Expected: PASS (all new + existing).

- [ ] **Step 5: Gates and commit**

Run: `cd frontend && npm run check && npx vitest run` — 0 errors, all green.

```bash
git add frontend/src/lib/markdown/agent-markdown.ts frontend/src/lib/markdown/agent-markdown.test.ts
git commit -m "feat(chat): path/URL detection helpers for agent message codespans

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Clickable codespans in the message renderer

**Files:**
- Modify: `frontend/src/lib/components/agent/markdown/MarkdownInline.svelte`
- Modify: `frontend/src/lib/components/agent/markdown/MarkdownBlocks.svelte`
- Modify: `frontend/src/lib/components/agent/MessageItem.svelte`
- Modify: `frontend/src/lib/components/agent/Transcript.svelte:59-61`

**Interfaces:**
- Consumes: `codespanFilePath`, `safeLinkHref`, `unescapeMarked` from `$lib/markdown/agent-markdown` (Task 1).
- Produces: `onOpenFile?: (relPath: string) => void` prop on `MessageItem`, `MarkdownBlocks`, `MarkdownInline`; `linked?: boolean` prop on `MarkdownInline` (internal guard). `Transcript` forwards its existing `onOpenFile` to assistant `MessageItem`s.

- [ ] **Step 1: MarkdownInline — props and codespan branch**

In `MarkdownInline.svelte`, change the imports and props:

```ts
import { codespanFilePath, safeLinkHref, unescapeMarked, type Token } from '$lib/markdown/agent-markdown';

let {
  tokens,
  onOpenFile,
  linked = false
}: {
  tokens: Token[];
  /** Opens an in-mount file by relPath — same handler the tool-card chips use (see Transcript). */
  onOpenFile?: (relPath: string) => void;
  /** True when already rendering inside an <a> — suppresses nested interactive codespans. */
  linked?: boolean;
} = $props();
```

Replace the codespan branch (currently the single `<code>` line) with:

```svelte
{:else if token.type === 'codespan'}
  {@const codeText = unescapeMarked(token.text ?? '')}
  {@const codeHref = linked ? null : safeLinkHref(codeText)}
  {@const codePath = linked || codeHref ? undefined : codespanFilePath(codeText)}
  {#if codeHref}
    <a
      href={codeHref}
      target="_blank"
      rel="noopener noreferrer"
      onclick={(event) => onLinkClick(event, codeHref)}
      class="bg-paper-track text-ink-heading decoration-paper-button-border rounded px-1 py-0.5 font-mono text-[12px] underline underline-offset-2 hover:decoration-ink-secondary"
      >{codeText}</a
    >
  {:else if codePath && onOpenFile}
    <button
      type="button"
      onclick={() => onOpenFile?.(codePath)}
      aria-label={`Open ${codePath}`}
      class="bg-paper-track hover:bg-paper-pill text-ink-body decoration-paper-button-border cursor-pointer rounded px-1 py-0.5 text-left font-mono text-[12px] underline underline-offset-2 transition-colors hover:decoration-ink-secondary"
      >{codeText}</button
    >
  {:else}
    <code class="bg-paper-track rounded px-1 py-0.5 font-mono text-[12px]">{codeText}</code>
  {/if}
```

Then update every `<MarkdownInline tokens={...} />` self-recursion in this file to forward the props — `{onOpenFile}` and `{linked}` on the text/strong/em/del branches and the no-href link fallback; the REAL `<a>` branch's inner recursion instead passes `linked={true}` (and forwards `{onOpenFile}` too — the guard, not the handler's absence, is what suppresses nesting):

```svelte
<MarkdownInline tokens={token.tokens ?? []} {onOpenFile} {linked} />          <!-- text/strong/em/del/no-href fallback -->
<MarkdownInline tokens={token.tokens ?? []} {onOpenFile} linked={true} />     <!-- inside the real <a> only -->
```

Also extend the component's header comment: codespans now earn a link (safeLinkHref-vetted, so http(s) AND mailto) or a file-open button (`codespanFilePath`); both render text via plain interpolation, and `linked` prevents interactive elements inside `<a>`.

- [ ] **Step 2: MarkdownBlocks — forward the prop**

Add to props:

```ts
let {
  tokens,
  onOpenFile
}: {
  tokens: Token[];
  /** Forwarded to every MarkdownInline (and recursive MarkdownBlocks) — see MarkdownInline. */
  onOpenFile?: (relPath: string) => void;
} = $props();
```

Add `{onOpenFile}` to ALL descendants in the template: the five `<MarkdownInline tokens={...} />` sites (paragraph, heading, table header cell, table body cell, loose text) and the three `<MarkdownBlocks tokens={...} />` self-recursions (ordered list item, unordered list item, blockquote). Fenced `code` blocks stay as-is.

- [ ] **Step 3: MessageItem — accept and forward**

```ts
let {
  role,
  text,
  onOpenFile
}: {
  role: 'user' | 'assistant';
  text: string;
  /** Forwarded to the markdown renderer so assistant prose can open files (assistant only). */
  onOpenFile?: (relPath: string) => void;
} = $props();
```

Assistant branch: `<MarkdownBlocks {tokens} {onOpenFile} />`. User branch unchanged (plain text).

- [ ] **Step 4: Transcript — wire assistant messages**

Change line 61's assistant branch to:

```svelte
<MessageItem role="assistant" text={asString(item.text)} {onOpenFile} />
```

(User-message line 59 stays without it.) Update the `onOpenFile` prop doc at lines 46-52: it now feeds ToolCallCard chips AND assistant-prose path codespans.

- [ ] **Step 5: Gates and commit**

Run: `cd frontend && npm run check && npx vitest run` — 0 errors, all green.

```bash
git add frontend/src/lib/components/agent/markdown/MarkdownInline.svelte frontend/src/lib/components/agent/markdown/MarkdownBlocks.svelte frontend/src/lib/components/agent/MessageItem.svelte frontend/src/lib/components/agent/Transcript.svelte
git commit -m "feat(chat): clickable file paths and URLs in agent message codespans

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Auto-open candidate module

**Files:**
- Create: `frontend/src/lib/components/agent/auto-open.ts`
- Test: `frontend/src/lib/components/agent/auto-open.test.ts`

**Interfaces:**
- Consumes: `AcpItemLike`, `asString` from `./item-shapes`; `messageFilePaths` from `$lib/markdown/agent-markdown` (Task 1).
- Produces: `turnCount(items: AcpItemLike[]): number` and `latestTurnAutoOpenPath(items: AcpItemLike[]): string | undefined`. Task 4 imports both by these exact names from `$lib/components/agent/auto-open`.

- [ ] **Step 1: Write the failing tests**

Create `frontend/src/lib/components/agent/auto-open.test.ts`:

```ts
import { describe, it, expect } from 'vitest';
import { turnCount, latestTurnAutoOpenPath } from './auto-open';
import type { AcpItemLike } from './item-shapes';

const user = (text: string): AcpItemLike => ({ id: 'u1', type: 'message', role: 'user', text });
const assistant = (id: string, text: string): AcpItemLike => ({ id, type: 'message', role: 'assistant', text });
const tool = (id: string): AcpItemLike => ({ id, type: 'tool', kind: 'read', status: 'completed' });
const turn = (id: string, stop: string, seq?: number): AcpItemLike =>
  seq === undefined
    ? { id, type: 'turn', stop_reason: stop }
    : { id, type: 'turn', stop_reason: stop, seq };

describe('turnCount', () => {
  it('counts turn items only', () => {
    expect(turnCount([])).toBe(0);
    expect(turnCount([user('hi'), assistant('m1', 'x'), turn('t1', 'end_turn', 5)])).toBe(1);
    expect(turnCount([turn('t1', 'end_turn'), turn('t2', 'error', 9)])).toBe(2);
  });
});

describe('latestTurnAutoOpenPath', () => {
  it('returns the single path of the latest live end_turn', () => {
    const items = [user('fetch it'), assistant('m1', 'It is `CONTEXT.md`.'), turn('t1', 'end_turn', 7)];
    expect(latestTurnAutoOpenPath(items)).toBe('CONTEXT.md');
  });

  it('skips tool/thought items between message and turn', () => {
    const items = [assistant('m1', 'See `notes/a.md`'), tool('x1'), turn('t1', 'end_turn', 3)];
    expect(latestTurnAutoOpenPath(items)).toBe('notes/a.md');
  });

  it('never fires for snapshot turns (no numeric seq)', () => {
    const items = [assistant('m1', 'See `CONTEXT.md`'), turn('t1', 'end_turn')];
    expect(latestTurnAutoOpenPath(items)).toBeUndefined();
  });

  it('never fires for non-end_turn stops', () => {
    const items = [assistant('m1', 'See `CONTEXT.md`'), turn('t1', 'error', 4)];
    expect(latestTurnAutoOpenPath(items)).toBeUndefined();
  });

  it('requires exactly one distinct path', () => {
    const two = [assistant('m1', '`a.md` or `b.md`'), turn('t1', 'end_turn', 4)];
    const none = [assistant('m1', 'no paths here'), turn('t1', 'end_turn', 4)];
    expect(latestTurnAutoOpenPath(two)).toBeUndefined();
    expect(latestTurnAutoOpenPath(none)).toBeUndefined();
  });

  it('uses only the LATEST turn and its own preceding assistant message', () => {
    const items = [
      assistant('m1', 'old `a.md`'),
      turn('t1', 'end_turn', 2),
      assistant('m2', 'new `b.md`'),
      turn('t2', 'end_turn', 6)
    ];
    expect(latestTurnAutoOpenPath(items)).toBe('b.md');
  });

  it('returns undefined when the turn has no assistant message, or no turns exist', () => {
    expect(latestTurnAutoOpenPath([user('hello'), turn('t1', 'end_turn', 2)])).toBeUndefined();
    expect(latestTurnAutoOpenPath([assistant('m1', '`a.md`')])).toBeUndefined();
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && npx vitest run src/lib/components/agent/auto-open.test.ts`
Expected: FAIL — module `./auto-open` does not exist.

- [ ] **Step 3: Implement the module**

Create `frontend/src/lib/components/agent/auto-open.ts`:

```ts
/**
 * Auto-open decision for agent replies that name a file (spec:
 * docs/superpowers/specs/2026-07-30-message-file-links-design.md §3).
 * Pure over the session store's ordered `items` so it is unit-testable
 * without a component harness — ChatView's effect owns the baseline
 * bookkeeping, the `icm_paths_exist` verification, and the actual open.
 */
import type { AcpItemLike } from './item-shapes';
import { asString } from './item-shapes';
import { messageFilePaths } from '$lib/markdown/agent-markdown';

/** How many turns the timeline holds — ChatView's baseline/increment signal. */
export function turnCount(items: AcpItemLike[]): number {
  let count = 0;
  for (const item of items) if (item.type === 'turn') count += 1;
  return count;
}

/**
 * The single openable path of the LATEST turn, or undefined. Fires only
 * when that turn (a) was delivered live — snapshot items carry no per-item
 * `seq`, only live pushes do (see AgentSessionStore's class doc), so a
 * seq-less turn is history replay and must never auto-open; (b) stopped
 * with `end_turn` (error/cancel turns carry other values); and (c) its
 * nearest preceding `message` item is an ASSISTANT message whose prose
 * names exactly one distinct candidate path (`messageFilePaths`). URLs are
 * never candidates — external navigation stays a deliberate click.
 */
export function latestTurnAutoOpenPath(items: AcpItemLike[]): string | undefined {
  let turnIndex = -1;
  for (let i = items.length - 1; i >= 0; i--) {
    if (items[i].type === 'turn') {
      turnIndex = i;
      break;
    }
  }
  if (turnIndex === -1) return undefined;
  const turn = items[turnIndex];
  if (typeof turn.seq !== 'number') return undefined;
  if (asString(turn.stop_reason) !== 'end_turn') return undefined;
  for (let i = turnIndex - 1; i >= 0; i--) {
    const item = items[i];
    if (item.type !== 'message') continue;
    if (asString(item.role) !== 'assistant') return undefined;
    const paths = messageFilePaths(asString(item.text));
    return paths.length === 1 ? paths[0] : undefined;
  }
  return undefined;
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && npx vitest run src/lib/components/agent/auto-open.test.ts`
Expected: PASS.

- [ ] **Step 5: Gates and commit**

Run: `cd frontend && npm run check && npx vitest run` — 0 errors, all green.

```bash
git add frontend/src/lib/components/agent/auto-open.ts frontend/src/lib/components/agent/auto-open.test.ts
git commit -m "feat(chat): pure auto-open candidate selection over session items

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Wire auto-open — PaneContext, /chat route, ChatView effect

**Files:**
- Modify: `frontend/src/lib/panes/context.ts`
- Modify: `frontend/src/routes/chat/+page.svelte:397` (the primary `ChatView`'s `context={{...}}`)
- Modify: `frontend/src/lib/components/views/ChatView.svelte` (new effect after the file-activity rail block, ~line 458)

**Interfaces:**
- Consumes: `turnCount`, `latestTurnAutoOpenPath` from `$lib/components/agent/auto-open` (Task 3); existing `api.icmPathsExist`, `openToolFile`, `openMountKey`, `context`, `store` in ChatView.
- Produces: `hasOpenPane?: () => boolean` on `PaneContext` (optional; absent = unknown = auto-open disabled).

- [ ] **Step 1: PaneContext gains `hasOpenPane`**

In `frontend/src/lib/panes/context.ts`, add to the `PaneContext` type after `openFile`:

```ts
  /**
   * Whether a side pane is currently open beside this view. Used by
   * ChatView's auto-open (message-file-links spec §3), which must never
   * replace what the user is viewing. Absent = unknown — auto-open then
   * conservatively never fires (views tolerate absent callbacks).
   */
  hasOpenPane?: () => boolean;
```

- [ ] **Step 2: /chat route wires it**

In `frontend/src/routes/chat/+page.svelte`, the primary ChatView (currently `context={{ placement: 'primary', openFile: openFilePane, onArchived: afterArchive }}`) becomes:

```svelte
context={{
  placement: 'primary',
  openFile: openFilePane,
  onArchived: afterArchive,
  hasOpenPane: () => paneDescriptor !== null
}}
```

(`paneDescriptor` already exists in this file, derived from `?pane=`. No other host changes — pane-hosted ChatViews are excluded by the placement guard anyway.)

- [ ] **Step 3: ChatView auto-open effect**

In `ChatView.svelte`, add imports:

```ts
import { turnCount, latestTurnAutoOpenPath } from '$lib/components/agent/auto-open';
```

Insert after the file-activity rail effect block (after `closeRail`/`reopenRail`, before `let viewWidth`):

```ts
// --- Auto-open a reply's single named file (message-file-links spec §3) ---
//
// Baseline is the turn count seen when THIS store attached — the OPPOSITE
// of the rail's fire-on-attach baseline: history must never open a pane.
// Each live increment is consumed exactly once (baseline advances even
// when a guard fails). The RPC verification captures store + turn count
// before the await and re-checks after (MarkdownPageView.refreshDangling's
// staleness shape) so a queued prompt starting the next turn mid-flight
// drops the result.
let autoOpenStore: AgentSessionStore | null = null;
let autoOpenBaseline = 0;
let autoOpenInFlight = false;

$effect(() => {
  const current = store;
  const count = current ? turnCount(current.items) : 0;
  if (current !== autoOpenStore) {
    autoOpenStore = current;
    autoOpenBaseline = count;
    return;
  }
  if (!current || count <= autoOpenBaseline) return;
  autoOpenBaseline = count;
  const open = openToolFile;
  if (!open || context.placement !== 'primary') return;
  if (context.hasOpenPane === undefined || context.hasOpenPane()) return;
  if (autoOpenInFlight) return;
  const relPath = latestTurnAutoOpenPath(current.items);
  const mount = openMountKey;
  if (!relPath || !mount) return;
  autoOpenInFlight = true;
  void verifyAndAutoOpen(current, count, mount, relPath, open);
});

async function verifyAndAutoOpen(
  captured: AgentSessionStore,
  capturedTurnCount: number,
  mount: string,
  relPath: string,
  open: (relPath: string) => void
): Promise<void> {
  try {
    const result = await api.icmPathsExist([`${mount}/${relPath}`]);
    if (!result.ok) return;
    const data = result.data as { results: { path: string; exists: boolean }[] };
    if (!data.results[0]?.exists) return;
    if (store !== captured || turnCount(captured.items) !== capturedTurnCount) return;
    if (context.hasOpenPane?.() !== false) return;
    open(relPath);
  } finally {
    autoOpenInFlight = false;
  }
}
```

(`api` is already imported in ChatView; `openToolFile` and `openMountKey` already exist. The `seq` gate inside `latestTurnAutoOpenPath` is the second history guard — a reopened session's snapshot turns carry no `seq`.)

- [ ] **Step 4: Gates and commit**

Run: `cd frontend && npm run check && npx vitest run` — 0 errors, all green.

```bash
git add frontend/src/lib/panes/context.ts frontend/src/routes/chat/+page.svelte frontend/src/lib/components/views/ChatView.svelte
git commit -m "feat(chat): auto-open the single file a completed reply names

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: Fake-adapter rig + manual browser verification

**Files:**
- Modify: `backend/test/support/fake_adapter.exs` (the `slow` scenario's closing `agent_message_chunk`)
- Temp (NOT committed): `/private/tmp/claude-501/-Users-daniel-Development-valea/5a15bea4-0971-419d-8875-54e428e3ad85/scratchpad/valea-app-dir/config.json`

**Interfaces:**
- Consumes: everything from Tasks 1-4; the `vt-backend`/`vt-frontend` launch entries in `.claude/launch.json`; the seeded app dir above (Second ICM contains a real `CONTEXT.md`).
- Produces: a `slow` run whose final message names exactly one in-mount path + one URL.

- [ ] **Step 1: Give the `slow` reply one path and one URL**

In `fake_adapter.exs`, replace the closing chunk's text (the `"done.\n\nHere is a longer reply…"` string) with:

```elixir
update(ctx, %{
  "sessionUpdate" => "agent_message_chunk",
  "content" => %{
    "type" => "text",
    "text" =>
      "done.\n\nThe note you asked about is `CONTEXT.md` — reference docs at " <>
        "`https://valea.example.com/docs`.\n\nStill a longer reply with running " <>
        "prose so the full-width assistant layout stays visible, plus a list:\n\n" <>
        "- first point\n- second point\n\nAnd a closing line."
  }
})
```

(Exactly ONE file-path codespan across the whole accumulated message — the earlier "Thinking this through… " chunk adds none; the URL codespan is never an auto-open candidate.)

- [ ] **Step 2: Point the seeded app dir at the fake adapter**

In the temp app-dir `config.json`, set:

```json
"harness_command": [
  "/Users/daniel/.asdf/shims/elixir",
  "-pa",
  "/Users/daniel/Development/valea/backend/_build/test/lib/jason/ebin",
  "/Users/daniel/Development/valea/backend/test/support/fake_adapter.exs",
  "slow"
]
```

- [ ] **Step 3: Manual browser pass**

Start `vt-backend` then `vt-frontend` via preview_start. CAUTION: preview_start caches launch configs by name within a session — if either name was already started this session with a DIFFERENT launch.json content, use a fresh config name (the vt-* entries themselves need no edits for this task). In the app (port 4374), start a NEW session in Second ICM (no pane open), send any prompt, and verify in order:

1. While streaming: nothing auto-opens.
2. After the ~4s of tool calls + final chunk + turn end: the file pane AUTO-OPENS `second-icm/CONTEXT.md` (URL gains `?pane=file%3Asecond-icm%2FCONTEXT.md`).
3. The message shows `CONTEXT.md` as a styled, clickable codespan (close the pane, click it — pane reopens) and `https://valea.example.com/docs` as an underlined link.
4. Reload the session URL (attach snapshot replay): NO auto-open fires.
5. Open some file pane manually, send another prompt: turn ends WITHOUT replacing the open pane.
6. read_console_messages shows no errors.

- [ ] **Step 4: Restore the rig and gates**

Restore the app-dir `config.json` `harness_command` to `["claude-agent-acp"]`; stop both preview servers.

Run: `cd frontend && npm run check && npx vitest run` (green), and `cd backend && mix format --check-formatted test/support/fake_adapter.exs`.

- [ ] **Step 5: Commit**

```bash
git add backend/test/support/fake_adapter.exs
git commit -m "test(rig): slow scenario reply names one file path and one URL

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```
