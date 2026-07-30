# Session File Activity Rail Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A right-hand rail in the chat view showing one row per file the session read/changed, with badges and hidden-by-default diffs, per `docs/superpowers/specs/2026-07-30-session-file-activity-design.md`.

**Architecture:** Pure-frontend. A new pure module (`file-activity.ts`) aggregates the session store's existing tool items into per-file rows; a new `FileActivityRail.svelte` renders them; `ChatView.svelte` hosts the rail (primary placement only, container-width gated) and wires auto-open, close memory, the existence cross-check, and the header's reopen toggle. No backend changes.

**Tech Stack:** Svelte 5 (runes), TypeScript, Vitest, Tailwind classes per the repo's design tokens. Reuses `item-shapes.ts` accessors, `lineDiff` + `DiffBlock`, `icmStore.ensurePathLoaded`.

## Global Constraints

- **Read the spec first**: `docs/superpowers/specs/2026-07-30-session-file-activity-design.md`. It is the authority on every behavior below.
- Frontend has **no prettier** — never run a formatter; match surrounding file style by hand.
- All file names, paths, and diff text are agent-produced: **plain Svelte interpolation only, `{@html}` is FORBIDDEN**.
- Repo test convention: pure logic in sibling `.ts` modules tested with Vitest; **no component render harness** — components stay thin over tested helpers.
- Frontend commands run from `frontend/`: `npm test` (vitest run), `npm run check` (svelte-check). Both must pass before every commit.
- Chronology comes from **timeline index** in `store.items`, never from `item.seq` (snapshot items carry no per-item seq).
- Commit after every task with the repo's conventional-commit style (`feat(chat): …`, `test(chat): …`).

---

### Task 1: `file-activity.ts` — types + `deriveFileActivity`

**Files:**
- Create: `frontend/src/lib/components/agent/file-activity.ts`
- Test: `frontend/src/lib/components/agent/file-activity.test.ts`

**Interfaces:**
- Consumes: `AcpItemLike`, `ToolDiff`, `asString`, `toolDiff`, `toolLocations` from `./item-shapes` (existing).
- Produces (later tasks rely on exact names):
  - `type FileBadge = 'read' | 'edited' | 'created' | 'deleted' | 'renamed'`
  - `type FileEdit = { diff?: ToolDiff }`
  - `type FileActivity = { key: string; relPath?: string; path: string; name: string; dir: string; kindBadge: FileBadge; read: boolean; edited: boolean; edits: FileEdit[]; lastIndex: number }`
  - `function deriveFileActivity(items: AcpItemLike[]): FileActivity[]`
  - `function splitPathName(p: string): { name: string; dir: string }`
  - `const CREATED_INFERENCE_ENABLED: boolean`

- [ ] **Step 1: Write the failing tests**

Create `frontend/src/lib/components/agent/file-activity.test.ts`. Helper + cases (this is the complete initial suite; `tool()` builds a minimal item):

```ts
import { describe, expect, it } from 'vitest';
import type { AcpItemLike } from './item-shapes';
import { deriveFileActivity, splitPathName } from './file-activity';

let nextId = 0;
function tool(over: Partial<AcpItemLike> & { [k: string]: unknown } = {}): AcpItemLike {
  return { id: `t${nextId++}`, type: 'tool', status: 'completed', ...over };
}
const loc = (relPath: string, path = `/ws/${relPath}`) => ({ path, relPath });

describe('deriveFileActivity', () => {
  it('one row per file, deduped across calls, read badge', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('notes/a.md')] }),
      tool({ kind: 'read', locations: [loc('notes/a.md')] })
    ]);
    expect(rows).toHaveLength(1);
    expect(rows[0]).toMatchObject({ key: 'notes/a.md', kindBadge: 'read', read: true, edited: false });
    expect(rows[0].edits).toHaveLength(0);
  });

  it('read then edit promotes to edited; diff lands in edits', () => {
    const diff = { path: 'notes/a.md', oldText: 'x\n', newText: 'y\n' };
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('notes/a.md')] }),
      tool({ kind: 'edit', locations: [loc('notes/a.md')], diff })
    ]);
    expect(rows[0].kindBadge).toBe('edited');
    expect(rows[0].read).toBe(true);
    expect(rows[0].edits).toEqual([{ diff: { path: 'notes/a.md', oldText: 'x\n', newText: 'y\n' } }]);
  });

  it('excludes failed and running calls', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', status: 'failed', locations: [loc('a.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'edit', status: 'in_progress', locations: [loc('b.md')] })
    ]);
    expect(rows).toHaveLength(0);
  });

  it('created: first edit diff with empty oldText and non-empty newText', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('new.md')], diff: { path: 'new.md', newText: 'hello\n' } })
    ]);
    expect(rows[0].kindBadge).toBe('created');
  });

  it('created inference misses empty-file creation (documented): stays edited', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('empty.md')], diff: { path: 'empty.md' } })
    ]);
    expect(rows[0].kindBadge).toBe('edited');
  });

  it('delete/move kinds badge deleted/renamed, no edits entries', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'delete', locations: [loc('gone.md')] }),
      tool({ kind: 'move', locations: [loc('to.md')] })
    ]);
    expect(rows.map((r) => r.kindBadge).sort()).toEqual(['deleted', 'renamed']);
    expect(rows.every((r) => r.edits.length === 0)).toBe(true);
  });

  it('badge precedence: delete beats edit beats read', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('a.md')] }),
      tool({ kind: 'edit', locations: [loc('a.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'delete', locations: [loc('a.md')] })
    ]);
    expect(rows[0].kindBadge).toBe('deleted');
  });

  it('multi-location edit: diff attaches to the diff.path match, others get diff-less entries', () => {
    const diff = { path: 'b.md', oldText: 'x', newText: 'y' };
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('a.md'), loc('b.md')], diff })
    ]);
    const a = rows.find((r) => r.key === 'a.md')!;
    const b = rows.find((r) => r.key === 'b.md')!;
    expect(b.edits).toEqual([{ diff }]);
    expect(a.edits).toEqual([{}]);
  });

  it('multi-location edit without a diff.path match: first location gets the diff', () => {
    const diff = { oldText: 'x', newText: 'y' };
    const rows = deriveFileActivity([
      tool({ kind: 'edit', locations: [loc('a.md'), loc('b.md')], diff })
    ]);
    expect(rows.find((r) => r.key === 'a.md')!.edits).toEqual([{ diff }]);
  });

  it('no locations but diff.path: synthesizes a non-openable row', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'edit', diff: { path: '/abs/x.md', oldText: 'a', newText: 'b' } })
    ]);
    expect(rows[0]).toMatchObject({ key: '/abs/x.md', relPath: undefined, kindBadge: 'edited' });
  });

  it('edit call with locations but no diff payload: edits entry preserved without diff', () => {
    const rows = deriveFileActivity([tool({ kind: 'edit', locations: [loc('a.md')] })]);
    expect(rows[0].edits).toEqual([{}]);
  });

  it('non-tool items and non-file kinds are ignored', () => {
    const rows = deriveFileActivity([
      { id: 'm1', type: 'message' },
      tool({ kind: 'execute', locations: [loc('a.md')] }),
      tool({ kind: 'search', locations: [loc('b.md')] })
    ]);
    expect(rows).toHaveLength(0);
  });

  it('sort: changed first, then most-recent lastIndex desc within groups', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [loc('r1.md')] }),
      tool({ kind: 'edit', locations: [loc('e1.md')], diff: { oldText: 'x', newText: 'y' } }),
      tool({ kind: 'read', locations: [loc('r2.md')] }),
      tool({ kind: 'edit', locations: [loc('e2.md')], diff: { oldText: 'x', newText: 'y' } })
    ]);
    expect(rows.map((r) => r.key)).toEqual(['e2.md', 'e1.md', 'r2.md', 'r1.md']);
  });

  it('outside-mount row keeps verbatim path, no relPath', () => {
    const rows = deriveFileActivity([
      tool({ kind: 'read', locations: [{ path: 'C:\\other\\doc.md' }] })
    ]);
    expect(rows[0]).toMatchObject({ key: 'C:\\other\\doc.md', relPath: undefined, name: 'doc.md', dir: 'C:\\other' });
  });
});

describe('splitPathName', () => {
  it('splits on forward slash', () => {
    expect(splitPathName('notes/deep/a.md')).toEqual({ name: 'a.md', dir: 'notes/deep' });
  });
  it('splits on backslash', () => {
    expect(splitPathName('C:\\ws\\a.md')).toEqual({ name: 'a.md', dir: 'C:\\ws' });
  });
  it('no separator: whole string is the name', () => {
    expect(splitPathName('a.md')).toEqual({ name: 'a.md', dir: '' });
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `cd frontend && npx vitest run src/lib/components/agent/file-activity.test.ts`
Expected: FAIL — cannot resolve `./file-activity`.

- [ ] **Step 3: Implement the module**

Create `frontend/src/lib/components/agent/file-activity.ts`:

```ts
/**
 * Session file-activity aggregation (file-activity rail — see
 * docs/superpowers/specs/2026-07-30-session-file-activity-design.md).
 * Pure: derives "which files did this session touch" from the timeline
 * items `AgentSessionStore` already holds. Chronology is the item's INDEX
 * in the ordered items array — snapshot items carry no per-item `seq`
 * (store class doc), so `seq` must never be used here.
 */
import type { AcpItemLike, ToolDiff, ToolLocation } from './item-shapes';
import { asString, toolDiff, toolLocations } from './item-shapes';

export type FileBadge = 'read' | 'edited' | 'created' | 'deleted' | 'renamed';

/** One completed edit call against a file; `diff` absent when the call carried none. */
export type FileEdit = { diff?: ToolDiff };

export type FileActivity = {
  key: string;
  relPath?: string;
  path: string;
  name: string;
  dir: string;
  kindBadge: FileBadge;
  read: boolean;
  edited: boolean;
  edits: FileEdit[];
  lastIndex: number;
};

/**
 * The `created` badge infers "new file" from an empty/absent `oldText` on the
 * file's FIRST completed edit diff. Nothing in the codebase proves overwrites
 * always carry `oldText` — this flag exists so the manual-acceptance pass can
 * flip it to false (falling back to `edited`) if a live overwrite arrives
 * without one. Known accepted miss while enabled: creating an EMPTY file (no
 * `newText`) shows `edited`.
 */
export const CREATED_INFERENCE_ENABLED = true;

/** Splits on `/` AND `\` — outside-mount paths arrive verbatim from the agent (Windows included). */
export function splitPathName(p: string): { name: string; dir: string } {
  const idx = Math.max(p.lastIndexOf('/'), p.lastIndexOf('\\'));
  return idx === -1 ? { name: p, dir: '' } : { name: p.slice(idx + 1), dir: p.slice(0, idx) };
}

const FILE_KINDS = new Set(['read', 'edit', 'delete', 'move']);

type Accum = {
  relPath?: string;
  path: string;
  read: boolean;
  edited: boolean;
  deleted: boolean;
  renamed: boolean;
  edits: FileEdit[];
  lastIndex: number;
};

function dedupeLocations(locations: ToolLocation[]): ToolLocation[] {
  const seen = new Set<string>();
  return locations.filter((l) => {
    const key = l.relPath ?? l.path;
    if (seen.has(key)) return false;
    seen.add(key);
    return true;
  });
}

/**
 * Deterministic diff→row attribution (spec): single location wins outright;
 * otherwise the location whose path/relPath equals or suffix-matches
 * `diff.path`; otherwise the first location.
 */
function pickDiffLocation(locations: ToolLocation[], diff: ToolDiff | undefined): ToolLocation | undefined {
  if (!diff) return undefined;
  if (locations.length <= 1) return locations[0];
  const target = diff.path;
  if (target) {
    const match = locations.find(
      (l) =>
        l.path === target ||
        l.relPath === target ||
        l.path.endsWith(`/${target}`) ||
        (l.relPath !== undefined && target.endsWith(`/${l.relPath}`))
    );
    if (match) return match;
  }
  return locations[0];
}

function badgeFor(a: Accum): FileBadge {
  if (a.deleted) return 'deleted';
  if (a.renamed) return 'renamed';
  if (a.edited && CREATED_INFERENCE_ENABLED) {
    const first = a.edits.find((e) => e.diff !== undefined);
    const d = first?.diff;
    if (d && !d.oldText && d.newText) return 'created';
  }
  if (a.edited) return 'edited';
  return 'read';
}

export function deriveFileActivity(items: AcpItemLike[]): FileActivity[] {
  const byKey = new Map<string, Accum>();

  const touch = (key: string, path: string, relPath: string | undefined, index: number): Accum => {
    const existing = byKey.get(key);
    if (existing) {
      existing.lastIndex = index;
      if (existing.relPath === undefined && relPath !== undefined) existing.relPath = relPath;
      return existing;
    }
    const created: Accum = {
      relPath,
      path,
      read: false,
      edited: false,
      deleted: false,
      renamed: false,
      edits: [],
      lastIndex: index
    };
    byKey.set(key, created);
    return created;
  };

  items.forEach((item, index) => {
    if (item.type !== 'tool') return;
    const kind = asString(item.kind);
    if (!FILE_KINDS.has(kind)) return;
    if (asString(item.status) !== 'completed') return;

    const locations = dedupeLocations(toolLocations(item));
    const diff = kind === 'edit' ? toolDiff(item) : undefined;

    if (locations.length === 0) {
      // Synthesize a row only for an edit that at least names its file.
      if (kind === 'edit' && diff?.path) {
        const acc = touch(diff.path, diff.path, undefined, index);
        acc.edited = true;
        acc.edits.push({ diff });
      }
      return;
    }

    const diffTarget = pickDiffLocation(locations, diff);
    for (const l of locations) {
      const acc = touch(l.relPath ?? l.path, l.path, l.relPath, index);
      if (kind === 'read') acc.read = true;
      if (kind === 'delete') acc.deleted = true;
      if (kind === 'move') acc.renamed = true;
      if (kind === 'edit') {
        acc.edited = true;
        acc.edits.push(l === diffTarget && diff ? { diff } : {});
      }
    }
  });

  return [...byKey.entries()]
    .map(([key, a]) => {
      const display = a.relPath ?? a.path;
      const { name, dir } = splitPathName(display);
      return {
        key,
        relPath: a.relPath,
        path: a.path,
        name,
        dir,
        kindBadge: badgeFor(a),
        read: a.read,
        edited: a.edited,
        edits: a.edits,
        lastIndex: a.lastIndex
      };
    })
    .sort((x, y) => {
      const xChanged = x.kindBadge !== 'read' ? 0 : 1;
      const yChanged = y.kindBadge !== 'read' ? 0 : 1;
      if (xChanged !== yChanged) return xChanged - yChanged;
      return y.lastIndex - x.lastIndex;
    });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && npx vitest run src/lib/components/agent/file-activity.test.ts`
Expected: PASS (all cases).

- [ ] **Step 5: Run the full frontend gate**

Run: `cd frontend && npm test && npm run check`
Expected: both PASS.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/agent/file-activity.ts frontend/src/lib/components/agent/file-activity.test.ts
git commit -m "feat(chat): file-activity aggregation — per-file rows from session tool items"
```

---

### Task 2: Visibility helpers — auto-open predicate + capped close memory

**Files:**
- Modify: `frontend/src/lib/components/agent/file-activity.ts` (append)
- Test: `frontend/src/lib/components/agent/file-activity.test.ts` (append)

**Interfaces:**
- Produces:
  - `function shouldAutoOpen(prevCount: number, count: number, closedByUser: boolean): boolean`
  - `class ClosedRailMemory { isClosed(id: string): boolean; close(id: string): void; reopen(id: string): void }`
  - `const closedRailMemory: ClosedRailMemory` (module singleton, cap 50)

- [ ] **Step 1: Write the failing tests** (append to the test file)

```ts
import { ClosedRailMemory, shouldAutoOpen } from './file-activity';

describe('shouldAutoOpen', () => {
  it('fires on the 0 -> >0 transition', () => {
    expect(shouldAutoOpen(0, 3, false)).toBe(true);
  });
  it('initial attach counts: prev 0 with a populated snapshot fires', () => {
    expect(shouldAutoOpen(0, 12, false)).toBe(true);
  });
  it('does not fire on later growth or when closed by user', () => {
    expect(shouldAutoOpen(3, 4, false)).toBe(false);
    expect(shouldAutoOpen(0, 3, true)).toBe(false);
    expect(shouldAutoOpen(0, 0, false)).toBe(false);
  });
});

describe('ClosedRailMemory', () => {
  it('remembers close, forgets on reopen', () => {
    const m = new ClosedRailMemory();
    m.close('s1');
    expect(m.isClosed('s1')).toBe(true);
    m.reopen('s1');
    expect(m.isClosed('s1')).toBe(false);
  });
  it('evicts the oldest beyond the cap of 50', () => {
    const m = new ClosedRailMemory();
    for (let i = 0; i < 51; i++) m.close(`s${i}`);
    expect(m.isClosed('s0')).toBe(false);
    expect(m.isClosed('s50')).toBe(true);
  });
});
```

- [ ] **Step 2: Run to verify the new cases fail**

Run: `cd frontend && npx vitest run src/lib/components/agent/file-activity.test.ts`
Expected: FAIL — `shouldAutoOpen` not exported.

- [ ] **Step 3: Implement** (append to `file-activity.ts`)

```ts
/** Auto-open fires only on the 0 -> >0 transition of the derived count (attach included). */
export function shouldAutoOpen(prevCount: number, count: number, closedByUser: boolean): boolean {
  return !closedByUser && prevCount === 0 && count > 0;
}

const MAX_CLOSED_REMEMBERED = 50;

/**
 * Per-session "the user closed the rail" memory — in-memory only (a fresh
 * app launch starts over, deliberately), capped so an arbitrarily long run
 * can't grow it unboundedly. Insertion-ordered Set gives FIFO eviction.
 */
export class ClosedRailMemory {
  #ids = new Set<string>();

  isClosed(id: string): boolean {
    return this.#ids.has(id);
  }

  close(id: string): void {
    this.#ids.delete(id);
    this.#ids.add(id);
    if (this.#ids.size > MAX_CLOSED_REMEMBERED) {
      const oldest = this.#ids.values().next().value;
      if (oldest !== undefined) this.#ids.delete(oldest);
    }
  }

  reopen(id: string): void {
    this.#ids.delete(id);
  }
}

export const closedRailMemory = new ClosedRailMemory();
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `cd frontend && npx vitest run src/lib/components/agent/file-activity.test.ts`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/agent/file-activity.ts frontend/src/lib/components/agent/file-activity.test.ts
git commit -m "feat(chat): rail auto-open predicate + capped per-session close memory"
```

---

### Task 3: Existence cross-check helper

**Files:**
- Modify: `frontend/src/lib/components/agent/file-activity.ts` (append)
- Test: `frontend/src/lib/components/agent/file-activity.test.ts` (append)

**Interfaces:**
- Consumes: `FileActivity` (Task 1). The ensure function's result mirrors `EnsurePathResult['status']` from `$lib/stores/icm.svelte` — but the helper takes a plain injected function so the test needs no store.
- Produces:
  - `function checkExistence(rows: FileActivity[], ensure: (relPath: string) => Promise<'found' | 'missing' | 'unavailable'>): Promise<Set<string>>` — resolves to the set of row `key`s **definitively missing**. Only rows with a changed badge (non-`read`) AND a `relPath` are checked; `'unavailable'`/`'found'` contribute nothing.

- [ ] **Step 1: Write the failing tests** (append)

```ts
import { checkExistence } from './file-activity';
import type { FileActivity } from './file-activity';

function row(over: Partial<FileActivity>): FileActivity {
  return {
    key: 'a.md', relPath: 'a.md', path: '/ws/a.md', name: 'a.md', dir: '',
    kindBadge: 'edited', read: false, edited: true, edits: [], lastIndex: 0,
    ...over
  };
}

describe('checkExistence', () => {
  it('flags only definitive missing on changed rows with relPath', async () => {
    const calls: string[] = [];
    const missing = await checkExistence(
      [
        row({ key: 'gone.md', relPath: 'gone.md' }),
        row({ key: 'still.md', relPath: 'still.md' }),
        row({ key: 'err.md', relPath: 'err.md' }),
        row({ key: 'read.md', relPath: 'read.md', kindBadge: 'read', edited: false, read: true }),
        row({ key: '/abs/out.md', relPath: undefined })
      ],
      async (relPath) => {
        calls.push(relPath);
        if (relPath === 'gone.md') return 'missing';
        if (relPath === 'err.md') return 'unavailable';
        return 'found';
      }
    );
    expect(missing).toEqual(new Set(['gone.md']));
    expect(calls.sort()).toEqual(['err.md', 'gone.md', 'still.md']);
  });
});
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd frontend && npx vitest run src/lib/components/agent/file-activity.test.ts`
Expected: FAIL — `checkExistence` not exported.

- [ ] **Step 3: Implement** (append to `file-activity.ts`)

```ts
/**
 * Existence cross-check (spec): reality-checks changed rows against the
 * mount tree. Caller injects `icmStore.ensurePathLoaded` (partially applied
 * with the mount key); ONLY a definitive `'missing'` marks a row —
 * `'unavailable'` (a listing failed) claims nothing, per the store's
 * issue-#2 contract. Sequential on purpose: `ensurePathLoaded` de-dupes
 * in-flight dir loads internally, and rail row counts are small.
 */
export async function checkExistence(
  rows: FileActivity[],
  ensure: (relPath: string) => Promise<'found' | 'missing' | 'unavailable'>
): Promise<Set<string>> {
  const missing = new Set<string>();
  for (const r of rows) {
    if (r.kindBadge === 'read' || r.relPath === undefined) continue;
    if ((await ensure(r.relPath)) === 'missing') missing.add(r.key);
  }
  return missing;
}
```

- [ ] **Step 4: Run tests to verify they pass, then the full gate**

Run: `cd frontend && npm test && npm run check`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/agent/file-activity.ts frontend/src/lib/components/agent/file-activity.test.ts
git commit -m "feat(chat): existence cross-check helper — definitive-missing only"
```

---

### Task 4: `FileActivityRail.svelte`

**Files:**
- Create: `frontend/src/lib/components/agent/FileActivityRail.svelte`
- Modify: `frontend/src/lib/components/agent/index.ts` (add export)

**Interfaces:**
- Consumes: `FileActivity`, `FileEdit` (Task 1); `DiffBlock` from `$lib/components/diff/DiffBlock.svelte`; `lineDiff` from `$lib/diff/line-diff`.
- Produces: component with props `{ activities: FileActivity[]; missingKeys: ReadonlySet<string>; onOpenFile?: (relPath: string) => void; onClose: () => void }`. Registered in `agent/index.ts` as `FileActivityRail`.

No component test (repo convention — logic already covered in Tasks 1–3).

- [ ] **Step 1: Write the component**

Create `frontend/src/lib/components/agent/FileActivityRail.svelte`:

```svelte
<script lang="ts">
  // The session file-activity rail (spec:
  // docs/superpowers/specs/2026-07-30-session-file-activity-design.md).
  // One row per touched file; badges tell read-only from changed; diffs are
  // hidden until a row is expanded. Presentational: aggregation, auto-open,
  // and existence checks are the host's job (ChatView) — this renders what
  // it is given.
  //
  // SECURITY: names, dirs, paths, and diff text are agent-produced content —
  // plain interpolation only, {@html} is FORBIDDEN (same rule as every
  // agent component).
  //
  // A11y (ToolCallCard precedent): the expand toggle and the open icon are
  // separate SIBLING buttons — the row container is a plain div, never a
  // nested-interactive control.
  import X from '@lucide/svelte/icons/x';
  import ChevronRight from '@lucide/svelte/icons/chevron-right';
  import ArrowUpRight from '@lucide/svelte/icons/arrow-up-right';
  import DiffBlock from '$lib/components/diff/DiffBlock.svelte';
  import { lineDiff } from '$lib/diff/line-diff';
  import type { FileActivity } from './file-activity';

  let {
    activities,
    missingKeys,
    onOpenFile,
    onClose
  }: {
    activities: FileActivity[];
    missingKeys: ReadonlySet<string>;
    onOpenFile?: (relPath: string) => void;
    onClose: () => void;
  } = $props();

  const BADGE_LABEL: Record<FileActivity['kindBadge'], string> = {
    read: 'Read',
    edited: 'Edited',
    created: 'Created',
    deleted: 'Deleted',
    renamed: 'Renamed'
  };

  let expandedKeys = $state(new Set<string>());

  function toggle(key: string): void {
    const next = new Set(expandedKeys);
    if (next.has(key)) next.delete(key);
    else next.add(key);
    expandedKeys = next;
  }
</script>

<aside class="border-paper-hairline flex w-[300px] shrink-0 flex-col border-l" aria-label="Files this session touched">
  <div class="border-paper-hairline flex items-center gap-2 border-b px-3 py-2">
    <span class="text-ink-heading text-[12.5px] font-medium">Files</span>
    <span class="text-ink-meta text-[11.5px]">{activities.length}</span>
    <span class="min-w-0 flex-1" aria-hidden="true"></span>
    <button
      type="button"
      onclick={onClose}
      aria-label="Close files panel"
      class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading flex size-5 items-center justify-center rounded-md transition-colors"
    >
      <X class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
    </button>
  </div>

  <div class="min-h-0 flex-1 overflow-y-auto py-1">
    {#each activities as row (row.key)}
      {@const expandable = row.edits.length > 0}
      {@const expanded = expandedKeys.has(row.key)}
      <div class="border-paper-hairline border-b last:border-b-0">
        <div class="flex items-start gap-1.5 px-2 py-1.5">
          <button
            type="button"
            onclick={() => toggle(row.key)}
            disabled={!expandable}
            aria-expanded={expandable ? expanded : undefined}
            aria-label={row.name}
            class={[
              'flex min-w-0 flex-1 items-start gap-1.5 rounded-md px-1 py-0.5 text-left',
              expandable ? 'hover:bg-paper-pill cursor-pointer' : 'cursor-default'
            ]}
          >
            <ChevronRight
              class={[
                'mt-0.5 size-3 shrink-0 text-ink-meta transition-transform',
                expanded ? 'rotate-90' : '',
                expandable ? '' : 'invisible'
              ]}
              strokeWidth={1.5}
              aria-hidden="true"
            />
            <span class="min-w-0 flex-1">
              <span class="block truncate text-[12.5px] font-medium text-ink-body">{row.name}</span>
              {#if row.dir}
                <span class="text-ink-meta block truncate font-mono text-[10.5px]">{row.dir}</span>
              {/if}
              <span class="text-ink-meta flex flex-wrap gap-x-2 text-[10.5px]">
                {#if row.edits.length > 1}<span>{row.edits.length} edits</span>{/if}
                {#if missingKeys.has(row.key)}<span class="italic">no longer exists</span>{/if}
              </span>
            </span>
            <span
              class={[
                'mt-0.5 shrink-0 rounded-md px-1.5 py-0.5 text-[10px] font-bold tracking-[0.04em] uppercase',
                row.kindBadge === 'read' ? 'bg-paper-pill text-ink-meta' : 'bg-act-tint text-act'
              ]}
            >
              {BADGE_LABEL[row.kindBadge]}
            </span>
          </button>
          {#if row.relPath !== undefined && onOpenFile}
            {@const relPath = row.relPath}
            <button
              type="button"
              onclick={() => onOpenFile?.(relPath)}
              aria-label={`Open ${row.name}`}
              title="Open file"
              class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading mt-0.5 flex size-5 shrink-0 items-center justify-center rounded-md transition-colors"
            >
              <ArrowUpRight class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
            </button>
          {/if}
        </div>

        {#if expanded}
          <div class="flex flex-col gap-1 pb-1.5">
            {#each row.edits as edit, i (i)}
              {#if edit.diff}
                {@const d = lineDiff(edit.diff.oldText ?? '', edit.diff.newText ?? '')}
                <DiffBlock rows={d.rows} truncated={d.truncated} />
              {:else}
                <p class="text-ink-meta px-3 text-[11px] italic">no change details available</p>
              {/if}
            {/each}
          </div>
        {/if}
      </div>
    {/each}
  </div>
</aside>
```

- [ ] **Step 2: Export it**

In `frontend/src/lib/components/agent/index.ts`, add (matching the file's existing export style):

```ts
export { default as FileActivityRail } from './FileActivityRail.svelte';
```

- [ ] **Step 3: Gate**

Run: `cd frontend && npm run check && npm test`
Expected: PASS (component compiles; no new tests).

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/agent/FileActivityRail.svelte frontend/src/lib/components/agent/index.ts
git commit -m "feat(chat): FileActivityRail component — badges, expandable diffs, open-in-pane"
```

---

### Task 5: SessionHeader "Files · N" reopen toggle

**Files:**
- Modify: `frontend/src/lib/components/agent/SessionHeader.svelte`

**Interfaces:**
- Produces: two new optional props on `SessionHeader`: `filesCount?: number` and `onShowFiles?: () => void`. The button renders only when `onShowFiles` is present AND `filesCount > 0` (the host passes `onShowFiles` only while the rail is closed).

- [ ] **Step 1: Add the props**

In the `$props()` destructure and type of `SessionHeader.svelte`, add:

```ts
    filesCount = 0,
    onShowFiles
```

and to the type:

```ts
    filesCount?: number;
    onShowFiles?: () => void;
```

- [ ] **Step 2: Render the toggle**

Immediately AFTER the `<span class="min-w-0 flex-1" aria-hidden="true"></span>` spacer line (so it sits right of center, left of the ellipsis menu), insert:

```svelte
    {#if onShowFiles && filesCount > 0}
      <button
        type="button"
        onclick={onShowFiles}
        class="text-ink-meta hover:bg-paper-pill hover:text-ink-heading rounded-md px-1.5 py-0.5 text-[11.5px] transition-colors"
      >
        Files · {filesCount}
      </button>
    {/if}
```

- [ ] **Step 3: Gate**

Run: `cd frontend && npm run check && npm test`
Expected: PASS.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/agent/SessionHeader.svelte
git commit -m "feat(chat): SessionHeader Files-count reopen toggle"
```

---

### Task 6: ChatView integration — rail hosting, auto-open, existence wiring

**Files:**
- Modify: `frontend/src/lib/components/views/ChatView.svelte`

**Interfaces:**
- Consumes: `deriveFileActivity`, `shouldAutoOpen`, `closedRailMemory`, `checkExistence` (Tasks 1–3); `FileActivityRail` (Task 4); `SessionHeader` props (Task 5); existing `openMountKey`, `openToolFile`, `context.placement`; `icmStore.ensurePathLoaded` and the `icmStore.groups` reassignment signal from `$lib/stores/icm.svelte` (NOT `onIcmChanged` — see Step 3's comment).
- Produces: the complete feature, wired.

- [ ] **Step 1: Imports**

Add to ChatView's script imports:

```ts
  import { FileActivityRail } from '$lib/components/agent';
  import {
    checkExistence,
    closedRailMemory,
    deriveFileActivity,
    shouldAutoOpen
  } from '$lib/components/agent/file-activity';
```

(`icmStore` is already imported.)

- [ ] **Step 2: Derivation + rail open/close state**

Add after the `openToolFile` derived block (end of the script):

```ts
  // --- File-activity rail (spec: 2026-07-30-session-file-activity-design) ---
  //
  // Aggregation is a plain derived over the same items the transcript reads.
  // Auto-open fires only on the derived count's 0 -> >0 transition (attach
  // included), and never for a session the user closed the rail on
  // (`closedRailMemory`, this app run only). Rendering is additionally gated
  // on primary placement and container width >= 860px — the rail yields to a
  // squeezed layout (e.g. an open side pane at PaneHost's 30% minimums).
  const fileActivities = $derived.by(() => (store ? deriveFileActivity(store.items) : []));

  let railOpen = $state(false);
  let railCountStore: AgentSessionStore | null = null;
  let previousFileCount = 0;

  $effect(() => {
    const current = store;
    const count = fileActivities.length;
    if (current !== railCountStore) {
      // New (or no) session: reset tracking, then let the 0 -> count check
      // below run against THIS session's own baseline.
      railCountStore = current;
      previousFileCount = 0;
      railOpen = false;
    }
    const id = sessionId;
    if (
      id !== null &&
      !railOpen &&
      shouldAutoOpen(previousFileCount, count, closedRailMemory.isClosed(id))
    ) {
      railOpen = true;
    }
    previousFileCount = count;
  });

  function closeRail(): void {
    railOpen = false;
    if (sessionId !== null) closedRailMemory.close(sessionId);
  }

  function reopenRail(): void {
    railOpen = true;
    if (sessionId !== null) closedRailMemory.reopen(sessionId);
  }

  let viewWidth = $state(0);
  const showRail = $derived(
    railOpen && context.placement === 'primary' && viewWidth >= 860 && fileActivities.length > 0
  );
```

(The rail's `onOpenFile` reuses the existing `openToolFile` derived — same `(relPath: string) => void` shape the tool-card chips use.)

- [ ] **Step 3: Existence cross-check wiring**

Add directly below Step 2's code:

```ts
  // Existence notes: reality-check changed rows against the mount tree via
  // `ensurePathLoaded` — ONLY its definitive 'missing' marks a row (store
  // issue-#2 contract). Re-runs when the changed-row set, mount, or rail
  // visibility changes, and whenever `icmStore.groups` is REASSIGNED — which
  // is how every `icm_changed` refetch lands. Deliberately NOT the
  // `onIcmChanged` listener: that fires BEFORE the refetch settles, so a
  // tick-based recheck would walk the stale tree through `loadDir`'s
  // loaded-dir cache and miss a deletion permanently (Codex review finding).
  // Reading `groups` cannot loop this effect: `ensurePathLoaded`'s own lazy
  // loads GRAFT into existing nodes without reassigning the array, and the
  // effect reads nothing deeper than the array reference.
  // The run token invalidates pending resolutions on EVERY re-run —
  // including the not-applicable branch, so a stale async result can never
  // land after the rail closed or the mount changed.
  let missingKeys = $state<ReadonlySet<string>>(new Set());
  let existenceRun = 0;

  const changedRelPaths = $derived(
    fileActivities
      .filter((r) => r.kindBadge !== 'read' && r.relPath !== undefined)
      .map((r) => r.key)
      .join('\n')
  );

  $effect(() => {
    void changedRelPaths;
    void icmStore.groups;
    const key = openMountKey;
    const token = ++existenceRun;
    if (!showRail || !key) {
      missingKeys = new Set();
      return;
    }
    const rows = fileActivities;
    void (async () => {
      const missing = await checkExistence(rows, async (relPath) => {
        const result = await icmStore.ensurePathLoaded(key, relPath);
        return result.status;
      });
      if (token === existenceRun) missingKeys = missing;
    })();
  });
```

- [ ] **Step 4: Layout — host the rail**

In the live-session branch (`{:else if store}`), wrap the existing centered column and add the rail as its sibling. Replace:

```svelte
  <div class="mx-auto flex min-h-0 w-full max-w-[660px] flex-1 flex-col px-4 pt-3">
```

(the one directly under the `{:else if store}` comment) and its matching closing `</div>` with:

```svelte
  <div bind:clientWidth={viewWidth} class="flex min-h-0 w-full flex-1">
    <div class="mx-auto flex min-h-0 w-full max-w-[660px] flex-1 flex-col px-4 pt-3">
      … (existing content: SessionHeader, archiveError, PlanBar, transcript scroller, starting/composer block — unchanged, re-indented one level) …
    </div>
    {#if showRail}
      <FileActivityRail
        activities={fileActivities}
        {missingKeys}
        onOpenFile={openToolFile}
        onClose={closeRail}
      />
    {/if}
  </div>
```

The `…` marker means keep the existing children exactly as they are — no content edits, indentation only. (The `chat-new` and doctor branches are untouched: no store, no rail.)

- [ ] **Step 5: Header toggle wiring**

On the live-session branch's `<SessionHeader …>`, add:

```svelte
      filesCount={fileActivities.length}
      onShowFiles={!railOpen ? reopenRail : undefined}
```

- [ ] **Step 6: Gate**

Run: `cd frontend && npm run check && npm test`
Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add frontend/src/lib/components/views/ChatView.svelte
git commit -m "feat(chat): host the file-activity rail — auto-open, close memory, existence notes"
```

---

### Task 7: Full verification + manual acceptance

**Files:** none new (fixes only if verification finds problems).

- [ ] **Step 1: Full frontend gate**

Run: `cd frontend && npm test && npm run check`
Expected: PASS. Fix anything that fails before proceeding.

- [ ] **Step 2: Manual acceptance in the running app**

Follow the repo's browser-testing rig (see `.claude/launch.json` / project docs — dev server via the preview tooling, NOT a bare `npm run dev` in a terminal the harness can't see). Walk the spec's manual list:

1. Start a session; ask the agent to read + edit files → rail auto-opens; rows show `Read`/`Edited`; edited row expands to a diff; `Read` rows have no chevron.
2. Ask the agent to create a new file → row shows `Created`. **Also ask it to overwrite an existing file and confirm the row stays `Edited` (i.e. the adapter sent `oldText`). If it shows `Created`, flip `CREATED_INFERENCE_ENABLED` to `false` (file-activity.ts documents this) and re-run this step expecting `Edited`. This sub-step is a MERGE GATE: the branch does not merge until it has been performed — the inference ships unverified until then (Codex review flag), and this is where it gets verified or disabled.**
3. ✕ close the rail → later file touches do NOT reopen it; header shows "Files · N"; clicking reopens.
4. ↗ on a row → file opens in the side pane; rail stays visible on a wide window; on a narrow window the rail yields (hides) while the pane is open.
5. Reopen a past session with file activity → rail auto-opens with its record.
6. Open the same session as a side pane (chat next to a file) → no rail.
7. Delete a rail-listed file on disk (e.g. via Finder/terminal) → row gains "no longer exists" after the icm-changed push.

- [ ] **Step 3: Commit any fixes**

```bash
git add -A frontend/src
git commit -m "fix(chat): file-activity rail acceptance fixes"
```

(Skip if nothing changed.)
