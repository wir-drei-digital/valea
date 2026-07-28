# Side Panes (Modular View Composition) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A file can open in a resizable side pane next to a chat session (via tool-card file chips and a session-header file-tree popover), and a chat session can open next to a file (via a session picker on the knowledge routes) — built on a generic view-component + registry + PaneHost pattern.

**Architecture:** Extract the chat and file route bodies into props-driven view components (`ChatView`, `FileView`); a pure `?pane=` URL codec plus a small registry lets a shared `PaneHost` render any registered view as a side pane inside the existing routes. `AppShell`'s `mainVariant` is absorbed into the views so any view can live in any pane. One small backend change relays ACP tool-call file locations.

**Tech Stack:** Svelte 5 (runes + snippets), SvelteKit 2 (SPA, adapter-static), Tailwind 4, bits-ui 2 (popover), paneforge (new), pdfjs-dist (new, lazy), Phoenix/Elixir backend, Vitest 4, ExUnit.

**Spec:** `docs/superpowers/specs/2026-07-28-side-panes-design.md`. One delta discovered during planning: the spec's backend change #2 (`icm_mount` on session summaries) **already exists** (`backend/lib/valea/agents.ex:371` emits `icm_mount`; `frontend/src/lib/api/client.ts:443` requests `icmMount`; `AgentSessionSummary.icmMount` is typed). No task re-adds it — Task 7 just consumes it.

## Global Constraints

- Frontend package manager is **bun** (`bun add`, `bun run`); backend is **mix**. Run frontend commands from `frontend/`, backend from `backend/`.
- **Never run prettier** on the frontend — it is not configured; do not reformat files you don't touch. Backend formatting is handled by a `mix format` hook automatically.
- Svelte 5 runes only (`$state`, `$derived`, `$props`, `$effect`, snippets). No legacy `svelte/store` in new code.
- **No component render harness exists.** All unit tests are pure logic in sibling `.ts`/`.exs` files (Vitest / ExUnit). Component correctness is verified with `bun run check` (svelte-check) + `bun run build`.
- `{@html}` is **forbidden** in every component under `lib/components/agent/` and for any agent/tool-authored string anywhere. Plain `{value}` interpolation only.
- Exactly **one** `workspace:events` channel join exists (root layout). Views/panes must never join it — subscribe via store listener sets (`icmStore.onIcmChanged`, …). Per-session `agent_session:<id>` channels (via `AgentSessionStore`) are fine, one per mounted ChatView.
- Backend path comparisons/relativization must use `Valea.Paths` (`ancestor?/3`, `relative_to/3`) — `Path.relative_to/2` is **forbidden** (see `backend/lib/valea/paths.ex` moduledoc).
- Commit after every task. End commit messages with:
  `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`
- Existing URLs must keep working: `/chat?session=…`, `/chat?all=1`, `/knowledge/<mountKey>/<path…>`, `?icm=`. The pane param is purely additive.

## File Structure

New:

| File | Responsibility |
|---|---|
| `frontend/src/lib/panes/pane-route.ts` | `PaneDescriptor` union; parse/serialize `?pane=`; equality; URL helper; titles; promote hrefs (pure, tested) |
| `frontend/src/lib/panes/pane-split.ts` | localStorage split-ratio persistence (pure, tested) |
| `frontend/src/lib/panes/registry.ts` | kind → Svelte component map (the ONLY file to touch when adding a future pane view) |
| `frontend/src/lib/components/panes/PaneHost.svelte` | primary + optional side pane, paneforge split, pane chrome (title / promote / close) |
| `frontend/src/lib/components/ui/popover/*` | shadcn-style wrapper over bits-ui Popover |
| `frontend/src/lib/components/shell/MainColumn.svelte` | scroll + width wrapper (absorbs old `mainVariant` prose/prose-wide) |
| `frontend/src/lib/components/views/ChatView.svelte` | extracted chat session view (props-driven) |
| `frontend/src/lib/components/views/FileView.svelte` | extracted file view: format dispatch |
| `frontend/src/lib/components/views/MarkdownPageView.svelte` | the `.md` editor experience (extracted from knowledge route) |
| `frontend/src/lib/components/files/raw-url.ts` | `/files/raw` URL builder |
| `frontend/src/lib/components/files/PlainTextView.svelte` | read-only monospace viewer |
| `frontend/src/lib/components/files/PdfView.svelte` | lazy pdf.js viewer |
| `frontend/src/lib/components/files/ImageView.svelte` | image viewer |
| `frontend/src/lib/components/agent/SessionHeader.svelte` | chat header: ICM name + file-tree popover + archive |
| `frontend/src/lib/components/knowledge/SessionPickerPopover.svelte` | mount-scoped recent sessions + "New session" |

Modified (headline): `backend/lib/valea/acp/connection.ex`, `frontend/src/lib/components/agent/item-shapes.ts`, `ToolCallCard.svelte`, `Transcript.svelte`, `AppShell.svelte`, `AppFrame.svelte`, `nav.ts`, `IcmTree.svelte`, `tiptap.css`, routes: `/` (today), `/chat`, `/knowledge`, `/knowledge/[...path]`, `/mail`, `/calendar`, `/sources`, `/audit`.

---

### Task 1: Backend — relay tool-call locations

**Files:**
- Modify: `backend/lib/valea/acp/connection.ex` (the `reduce_update` clause for `tool_call`/`tool_call_update` at ~line 646, plus new private helpers near `put_tool_content/2` at ~line 770)
- Test: `backend/test/valea/acp/connection_test.exs`

**Interfaces:**
- Consumes: `state.launch.cwd` (absolute ICM root the session runs in — the test harness boots with `"/ws"`), `Valea.Paths.absolute?/1`, `Valea.Paths.ancestor?/2`, `Valea.Paths.relative_to/2`.
- Produces: tool items may now carry `"locations" => [%{"path" => String.t(), "relPath" => String.t() (optional), "line" => integer (optional)}]`. `relPath` is present iff the file lies inside the session cwd (or the ACP path was already relative). Later location-less updates must NOT erase earlier locations. Task 2's frontend accessor depends on exactly these keys.

- [ ] **Step 1: Write the failing tests**

Append to `backend/test/valea/acp/connection_test.exs` (conventions: `connected_state/0` boots with cwd `"/ws"`; `update/2` wraps a `session/update` frame — both already in the file):

```elixir
  # === Tool-call locations (side-panes pass) ===

  test "tool_call relays locations; cwd-contained paths gain relPath" do
    state = connected_state()

    {_state, items, _replies, _effects} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "t-loc",
          "title" => "Read notes.md",
          "kind" => "read",
          "status" => "in_progress",
          "locations" => [
            %{"path" => "/ws/notes/notes.md", "line" => 12},
            %{"path" => "/etc/passwd"},
            %{"path" => "already/relative.md"},
            %{"path" => ""},
            %{"nope" => true}
          ]
        })
      )

    assert [%{"locations" => locs}] = items

    assert locs == [
             %{"path" => "/ws/notes/notes.md", "relPath" => "notes/notes.md", "line" => 12},
             %{"path" => "/etc/passwd"},
             %{"path" => "already/relative.md", "relPath" => "already/relative.md"}
           ]
  end

  test "location-less tool_call_update preserves earlier locations" do
    state = connected_state()

    {state, _items, _replies, _effects} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{
          "toolCallId" => "t-keep",
          "status" => "in_progress",
          "locations" => [%{"path" => "/ws/a.md"}]
        })
      )

    {_state, items, _replies, _effects} =
      Connection.handle_bytes(
        state,
        update("tool_call_update", %{"toolCallId" => "t-keep", "status" => "completed"})
      )

    assert [%{"status" => "completed", "locations" => [%{"path" => "/ws/a.md", "relPath" => "a.md"}]}] =
             items
  end

  test "empty or malformed locations list sets no locations key" do
    state = connected_state()

    {_state, items, _replies, _effects} =
      Connection.handle_bytes(
        state,
        update("tool_call", %{"toolCallId" => "t-none", "status" => "in_progress", "locations" => []})
      )

    assert [item] = items
    refute Map.has_key?(item, "locations")
  end
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `backend/`): `mix test test/valea/acp/connection_test.exs`
Expected: the three new tests FAIL (no `"locations"` key on items); all pre-existing tests PASS.

- [ ] **Step 3: Implement the relay**

In the `reduce_update` clause for `tool_call`/`tool_call_update` (~line 646), add one pipe step after `put_tool_content`:

```elixir
    item =
      prev
      |> merge_present(u, "title")
      |> merge_present(u, "kind")
      |> merge_present(u, "status")
      |> put_tool_content(u["content"])
      |> put_tool_locations(u["locations"], state.launch.cwd)
```

Add the helpers next to `put_tool_content/2` (~line 770):

```elixir
  # Relay ACP `toolCall.locations` (file paths a tool touched) onto the tool
  # item so the frontend can offer "open this file" affordances (side-panes
  # pass). Only set when THIS update carries a non-empty list — a later
  # location-less update must not erase them (same rule as "diff"). Each
  # entry keeps the raw "path" and gains "relPath" when the file lies inside
  # the session's cwd (the ICM root): already-relative paths are taken as
  # cwd-relative verbatim; absolute ones relativize via the case-folded
  # `Valea.Paths` helpers — never `Path.relative_to/2` (see Paths moduledoc).
  defp put_tool_locations(item, locations, cwd) when is_list(locations) do
    rendered =
      for loc <- locations,
          is_map(loc),
          path = loc["path"],
          is_binary(path),
          path != "" do
        %{"path" => path}
        |> put_location_line(loc["line"])
        |> put_location_rel(path, cwd)
      end

    if rendered == [], do: item, else: Map.put(item, "locations", rendered)
  end

  defp put_tool_locations(item, _locations, _cwd), do: item

  defp put_location_line(entry, line) when is_integer(line), do: Map.put(entry, "line", line)
  defp put_location_line(entry, _line), do: entry

  defp put_location_rel(entry, path, cwd) when is_binary(cwd) do
    cond do
      not Valea.Paths.absolute?(path) ->
        Map.put(entry, "relPath", path)

      Valea.Paths.ancestor?(cwd, path) ->
        case Valea.Paths.relative_to(path, cwd) do
          "." -> entry
          rel -> Map.put(entry, "relPath", rel)
        end

      true ->
        entry
    end
  end

  defp put_location_rel(entry, _path, _cwd), do: entry
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `backend/`): `mix test test/valea/acp/connection_test.exs`
Expected: ALL PASS. Then run the full suite: `mix test` — no regressions.

- [ ] **Step 5: Commit**

```bash
git add backend/lib/valea/acp/connection.ex backend/test/valea/acp/connection_test.exs
git commit -m "feat(backend): relay ACP tool-call locations on tool items

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 2: Frontend — `toolLocations` accessor

**Files:**
- Modify: `frontend/src/lib/components/agent/item-shapes.ts`
- Test: `frontend/src/lib/components/agent/item-shapes.test.ts` (extend if it exists, create otherwise)

**Interfaces:**
- Consumes: Task 1's wire shape `item.locations = [{path, relPath?, line?}]`; existing `AcpItemLike`, `asPresentString`.
- Produces: `export type ToolLocation = { path: string; relPath?: string; line?: number }` and `export function toolLocations(item: AcpItemLike): ToolLocation[]`. Task 8's `ToolCallCard` chips consume this — chips are clickable iff `relPath` is present.

- [ ] **Step 1: Write the failing test**

In `frontend/src/lib/components/agent/item-shapes.test.ts` (follow the file's existing style if present; otherwise standard Vitest):

```ts
import { describe, expect, it } from 'vitest';
import { toolLocations } from './item-shapes';

describe('toolLocations', () => {
  it('returns typed locations, keeping relPath/line only when valid', () => {
    const item = {
      id: 't1',
      type: 'tool',
      locations: [
        { path: '/ws/notes/a.md', relPath: 'notes/a.md', line: 12 },
        { path: '/etc/passwd' },
        { path: '/ws/x.md', relPath: '', line: 'nope' },
        { path: '' },
        { relPath: 'orphan.md' },
        null,
        'junk'
      ]
    };
    expect(toolLocations(item)).toEqual([
      { path: '/ws/notes/a.md', relPath: 'notes/a.md', line: 12 },
      { path: '/etc/passwd', relPath: undefined, line: undefined },
      { path: '/ws/x.md', relPath: undefined, line: undefined }
    ]);
  });

  it('returns [] when locations is absent or not an array', () => {
    expect(toolLocations({ id: 't', type: 'tool' })).toEqual([]);
    expect(toolLocations({ id: 't', type: 'tool', locations: 'x' })).toEqual([]);
  });
});
```

- [ ] **Step 2: Run test to verify it fails**

Run (from `frontend/`): `bun run test src/lib/components/agent/item-shapes.test.ts`
Expected: FAIL — `toolLocations` is not exported.

- [ ] **Step 3: Implement the accessor**

Append to `item-shapes.ts` (after `toolDiff`/`diffLines`, matching the file's doc-comment style — source the shape from `Connection.put_tool_locations/3`):

```ts
export type ToolLocation = { path: string; relPath?: string; line?: number };

/**
 * `item.locations` as relayed by `Connection.put_tool_locations/3`:
 * `[{path, relPath?, line?}]`. `relPath` (ICM-root-relative) is present only
 * when the file lies inside the session's cwd — it is what file-open
 * affordances key off; entries without it render as plain text.
 */
export function toolLocations(item: AcpItemLike): ToolLocation[] {
  const raw = item.locations;
  if (!Array.isArray(raw)) return [];

  return raw.flatMap((l): ToolLocation[] => {
    if (!l || typeof l !== 'object') return [];
    const rec = l as Record<string, unknown>;
    const path = rec.path;
    if (typeof path !== 'string' || path.length === 0) return [];
    return [
      {
        path,
        relPath: asPresentString(rec.relPath),
        line: typeof rec.line === 'number' ? rec.line : undefined
      }
    ];
  });
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run (from `frontend/`): `bun run test src/lib/components/agent/item-shapes.test.ts` — PASS. Then `bun run test` (whole suite) — no regressions.

- [ ] **Step 5: Commit**

```bash
git add frontend/src/lib/components/agent/item-shapes.ts frontend/src/lib/components/agent/item-shapes.test.ts
git commit -m "feat(chat): toolLocations accessor for relayed tool-call locations

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 3: Pane URL codec + split persistence

**Files:**
- Create: `frontend/src/lib/panes/pane-route.ts`
- Create: `frontend/src/lib/panes/pane-split.ts`
- Test: `frontend/src/lib/panes/pane-route.test.ts`, `frontend/src/lib/panes/pane-split.test.ts`

**Interfaces:**
- Consumes: `encodePath`, `knowledgeHref` from `$lib/shell/nav` (leaf pure module — safe import).
- Produces (Tasks 8–9 depend on these exact signatures):
  - `type FilePaneDescriptor = { kind: 'file'; mountKey: string; path: string }`
  - `type ChatPaneDescriptor = { kind: 'chat'; sessionId: string }`
  - `type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string }`
  - `type PaneDescriptor = FilePaneDescriptor | ChatPaneDescriptor | ChatNewPaneDescriptor`
  - `parsePaneParam(raw: string | null): PaneDescriptor | null`
  - `serializePaneParam(d: PaneDescriptor): string`
  - `panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean`
  - `withPaneParam(url: URL, d: PaneDescriptor | null): string` (pathname+search string for `goto`)
  - `paneTitle(d: PaneDescriptor): string`
  - `promoteHref(d: PaneDescriptor): string`
  - `loadPaneSplit(): number` / `savePaneSplit(pct: number): void` (percent for the PRIMARY pane, clamped 30–70, default 60; key `valea.pane-split`)

- [ ] **Step 1: Write the failing tests**

`frontend/src/lib/panes/pane-route.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import {
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
  it.each([null, '', 'file', 'file:', 'file:onlymount', 'file:/no-mount', 'file:m/', 'chat:', 'chat:new:', 'mail:x', ':x', 'file:m/%E0%A4%A'])(
    '%s -> null',
    (raw) => {
      expect(parsePaneParam(raw as string | null)).toBeNull();
    }
  );
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
```

`frontend/src/lib/panes/pane-split.test.ts` (jsdom localStorage is available in this vitest setup — mirror `tree-state.test.ts`'s approach if it differs):

```ts
import { beforeEach, describe, expect, it } from 'vitest';
import { loadPaneSplit, savePaneSplit } from './pane-split';

describe('pane split persistence', () => {
  beforeEach(() => localStorage.clear());

  it('defaults to 60', () => {
    expect(loadPaneSplit()).toBe(60);
  });

  it('round-trips and clamps to 30..70', () => {
    savePaneSplit(55.4);
    expect(loadPaneSplit()).toBe(55);
    savePaneSplit(10);
    expect(loadPaneSplit()).toBe(30);
    savePaneSplit(95);
    expect(loadPaneSplit()).toBe(70);
  });

  it('ignores garbage stored values', () => {
    localStorage.setItem('valea.pane-split', 'junk');
    expect(loadPaneSplit()).toBe(60);
  });
});
```

- [ ] **Step 2: Run tests to verify they fail**

Run (from `frontend/`): `bun run test src/lib/panes/`
Expected: FAIL — modules don't exist.

- [ ] **Step 3: Implement `pane-route.ts`**

```ts
/**
 * Pure codec for the `?pane=` query param (side-panes pass) — which view is
 * open in the side pane next to the route's primary view. Same
 * "extract the logic, no component render harness" convention as
 * `icm-route.ts`. Wire forms:
 *
 *   file:<mountKey>/<relPath>   (mountKey and each path segment URL-encoded,
 *                                mirroring `knowledgeHref`)
 *   chat:<sessionId>
 *   chat:new:<mountKey>         (new-session composer scoped to that ICM;
 *                                rewritten to chat:<id> once the session starts)
 *
 * Invalid input parses to null — the caller renders the primary alone.
 */
import { encodePath, knowledgeHref } from '$lib/shell/nav';

export type FilePaneDescriptor = { kind: 'file'; mountKey: string; path: string };
export type ChatPaneDescriptor = { kind: 'chat'; sessionId: string };
export type ChatNewPaneDescriptor = { kind: 'chat-new'; mountKey: string };
export type PaneDescriptor = FilePaneDescriptor | ChatPaneDescriptor | ChatNewPaneDescriptor;

function tryDecode(segment: string): string | null {
  try {
    return decodeURIComponent(segment);
  } catch {
    return null;
  }
}

export function parsePaneParam(raw: string | null): PaneDescriptor | null {
  if (!raw) return null;
  const colon = raw.indexOf(':');
  if (colon <= 0) return null;
  const kind = raw.slice(0, colon);
  const rest = raw.slice(colon + 1);

  if (kind === 'file') {
    const slash = rest.indexOf('/');
    if (slash <= 0 || slash === rest.length - 1) return null;
    const mountKey = tryDecode(rest.slice(0, slash));
    if (!mountKey) return null;
    const segments = rest.slice(slash + 1).split('/').map(tryDecode);
    if (segments.some((s) => s === null || s === '')) return null;
    return { kind: 'file', mountKey, path: (segments as string[]).join('/') };
  }

  if (kind === 'chat') {
    if (rest.startsWith('new:')) {
      const mountKey = tryDecode(rest.slice('new:'.length));
      return mountKey ? { kind: 'chat-new', mountKey } : null;
    }
    const sessionId = tryDecode(rest);
    return sessionId ? { kind: 'chat', sessionId } : null;
  }

  return null;
}

export function serializePaneParam(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return `file:${encodeURIComponent(d.mountKey)}/${encodePath(d.path)}`;
    case 'chat':
      return `chat:${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `chat:new:${encodeURIComponent(d.mountKey)}`;
  }
}

/** Identity comparison — used to reject a side pane duplicating the primary view. Null never equals anything (including null). */
export function panesEqual(a: PaneDescriptor | null, b: PaneDescriptor | null): boolean {
  if (!a || !b || a.kind !== b.kind) return false;
  switch (a.kind) {
    case 'file':
      return b.kind === 'file' && a.mountKey === b.mountKey && a.path === b.path;
    case 'chat':
      return b.kind === 'chat' && a.sessionId === b.sessionId;
    case 'chat-new':
      return b.kind === 'chat-new' && a.mountKey === b.mountKey;
  }
}

/** The `goto` target for the current URL with the pane param set (or removed when `d` is null). Preserves every other param. */
export function withPaneParam(url: URL, d: PaneDescriptor | null): string {
  const next = new URL(url);
  if (d) next.searchParams.set('pane', serializePaneParam(d));
  else next.searchParams.delete('pane');
  return next.pathname + next.search;
}

/** Pane-chrome title. Kept static/pure (no store lookups) — the view inside the pane carries its own richer header. */
export function paneTitle(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return d.path.split('/').pop() ?? d.path;
    case 'chat':
      return 'Chat';
    case 'chat-new':
      return 'New session';
  }
}

/** Where the pane-chrome "open as full view" button navigates. */
export function promoteHref(d: PaneDescriptor): string {
  switch (d.kind) {
    case 'file':
      return knowledgeHref(d.mountKey, d.path);
    case 'chat':
      return `/chat?session=${encodeURIComponent(d.sessionId)}`;
    case 'chat-new':
      return `/chat?icm=${encodeURIComponent(d.mountKey)}`;
  }
}
```

- [ ] **Step 4: Implement `pane-split.ts`**

```ts
/**
 * Persisted split ratio for PaneHost (percent width of the PRIMARY pane).
 * Same localStorage pattern as `tree-state.svelte.ts` — storage failures
 * (private mode, disabled storage) degrade to the default silently.
 */
const KEY = 'valea.pane-split';
const DEFAULT = 60;
const MIN = 30;
const MAX = 70;

function clamp(pct: number): number {
  return Math.min(MAX, Math.max(MIN, Math.round(pct)));
}

export function loadPaneSplit(): number {
  try {
    const raw = localStorage.getItem(KEY);
    if (raw === null) return DEFAULT;
    const parsed = Number(raw);
    return Number.isFinite(parsed) ? clamp(parsed) : DEFAULT;
  } catch {
    return DEFAULT;
  }
}

export function savePaneSplit(pct: number): void {
  try {
    localStorage.setItem(KEY, String(clamp(pct)));
  } catch {
    // best-effort persistence only
  }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run (from `frontend/`): `bun run test src/lib/panes/` — PASS. Then `bun run check` — clean.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/panes/
git commit -m "feat(panes): ?pane= descriptor codec and split persistence

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 4: Popover UI primitive

**Files:**
- Create: `frontend/src/lib/components/ui/popover/popover.svelte`, `popover-trigger.svelte`, `popover-content.svelte`, `index.ts`

**Interfaces:**
- Consumes: `bits-ui`'s `Popover` namespace (installed, v2.18); `cn` from `$lib/utils` (same import the dialog/dropdown wrappers use — verify the exact path in `ui/dialog/dialog-content.svelte` and match it).
- Produces: `import * as Popover from '$lib/components/ui/popover'` with `Popover.Root`, `Popover.Trigger`, `Popover.Content`. Tasks 7/9 consume this. `Popover.Content` accepts `class`, `align`, `sideOffset` and renders into a portal with the app's popover styling.

- [ ] **Step 1: Read the local conventions**

Read `frontend/src/lib/components/ui/dialog/dialog-content.svelte` and `frontend/src/lib/components/ui/dropdown-menu/dropdown-menu-content.svelte` (styling + `cn` import path + `data-slot` conventions). The popover files below must match those conventions exactly — adjust the `cn` import and class tokens to what those files actually use.

- [ ] **Step 2: Create the wrapper**

`popover.svelte`:

```svelte
<script lang="ts">
  import { Popover as PopoverPrimitive } from 'bits-ui';
  let { open = $bindable(false), ...restProps }: PopoverPrimitive.RootProps = $props();
</script>

<PopoverPrimitive.Root bind:open {...restProps} />
```

`popover-trigger.svelte`:

```svelte
<script lang="ts">
  import { Popover as PopoverPrimitive } from 'bits-ui';
  let { ref = $bindable(null), ...restProps }: PopoverPrimitive.TriggerProps = $props();
</script>

<PopoverPrimitive.Trigger bind:ref data-slot="popover-trigger" {...restProps} />
```

`popover-content.svelte` (class list: copy the dropdown-menu content's surface tokens — `bg-popover text-popover-foreground` etc. — verbatim from the local file):

```svelte
<script lang="ts">
  import { Popover as PopoverPrimitive } from 'bits-ui';
  import { cn } from '$lib/utils.js';

  let {
    ref = $bindable(null),
    class: className,
    align = 'start',
    sideOffset = 4,
    ...restProps
  }: PopoverPrimitive.ContentProps = $props();
</script>

<PopoverPrimitive.Portal>
  <PopoverPrimitive.Content
    bind:ref
    data-slot="popover-content"
    {align}
    {sideOffset}
    class={cn(
      'bg-popover text-popover-foreground z-50 w-80 rounded-md border p-0 shadow-md outline-none',
      className
    )}
    {...restProps}
  />
</PopoverPrimitive.Portal>
```

`index.ts`:

```ts
import Root from './popover.svelte';
import Trigger from './popover-trigger.svelte';
import Content from './popover-content.svelte';

export { Root, Trigger, Content, Root as Popover, Trigger as PopoverTrigger, Content as PopoverContent };
```

- [ ] **Step 3: Verify**

Run (from `frontend/`): `bun run check` — clean (unused-export warnings aside). If bits-ui's prop types differ (e.g. no `ref` bindable on this version), match whatever `ui/dialog/*` does for the same concern.

- [ ] **Step 4: Commit**

```bash
git add frontend/src/lib/components/ui/popover/
git commit -m "feat(ui): popover primitive wrapper over bits-ui

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 5: AppShell variant absorption

**Files:**
- Modify: `frontend/src/lib/components/shell/AppShell.svelte`, `AppFrame.svelte`, `frontend/src/lib/components/shell/index.ts`
- Create: `frontend/src/lib/components/shell/MainColumn.svelte`
- Modify (mechanical, one wrapper each): `frontend/src/routes/+page.svelte` (Today), `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte`, `frontend/src/routes/mail/+page.svelte`, `frontend/src/routes/sources/+page.svelte`, `frontend/src/routes/audit/+page.svelte`, `frontend/src/routes/calendar/+page.svelte`, `frontend/src/routes/chat/+page.svelte`

**Interfaces:**
- Produces: `AppShell`/`AppFrame` no longer take `mainVariant`; `main` is always `<main class="flex min-h-0 min-w-0 flex-1 flex-col">`. New `MainColumn` component (exported from the shell barrel): props `{ wide?: boolean; children: Snippet }` — the scroll+width wrapper routes now own. Tasks 6–9 rely on the main slot being a bare flex column.

Behavior-preserving refactor: every route must render pixel-identically after this task.

- [ ] **Step 1: Rewrite `AppShell.svelte`'s main region**

Remove the `mainVariant` prop and the three-way branch (lines 47–63). The main region becomes exactly:

```svelte
  <main class="flex min-h-0 min-w-0 flex-1 flex-col">
    {@render main()}
  </main>
```

Update the doc comment: variants are absorbed into views (side-panes pass) — each route/view owns its own scroll container and width caps; keep the §11 grid note and the Resizable note.

- [ ] **Step 2: Update `AppFrame.svelte`**

Remove `mainVariant` from props and from the `<AppShell …>` call (it forwards everything else unchanged).

- [ ] **Step 3: Create `MainColumn.svelte` and export it**

```svelte
<script lang="ts">
  // The old AppShell 'prose' / 'prose-wide' main variants, relocated to the
  // route layer (side-panes pass): a scrolling column with either the §11
  // centered 660px prose cap (default) or the full pane width with just the
  // gutter (wide — page-editor pages, which re-cap per-block via tiptap.css).
  import type { Snippet } from 'svelte';

  let { wide = false, children }: { wide?: boolean; children: Snippet } = $props();
</script>

<div class="min-h-0 flex-1 overflow-y-auto">
  <div class={wide ? 'px-8 py-8' : 'mx-auto max-w-[660px] px-8 py-8'}>
    {@render children()}
  </div>
</div>
```

Add `MainColumn` to `frontend/src/lib/components/shell/index.ts` exports.

- [ ] **Step 4: Update every route**

- `chat/+page.svelte`: change `<AppFrame mainVariant="column" …>` → `<AppFrame …>`. Its main snippet already renders a full-height column — no wrapper.
- `calendar/+page.svelte`: change `<AppFrame mainVariant="column">` → `<AppFrame>`. No wrapper.
- `knowledge/[...path]/+page.svelte`: change `<AppFrame onBeforeMutateActive={flushBeforeMutate} mainVariant="prose-wide">` → `<AppFrame onBeforeMutateActive={flushBeforeMutate}>`, and wrap the ENTIRE contents of its `{#snippet main()}` in `<MainColumn wide>…</MainColumn>` (import `MainColumn` from `$lib/components/shell`).
- `knowledge/+page.svelte`, `mail/+page.svelte`, `sources/+page.svelte`, `audit/+page.svelte`: wrap each `{#snippet main()}` body in `<MainColumn>…</MainColumn>`.
- `+page.svelte` (Today — composes `AppShell` directly): wrap its `main` snippet body in `<MainColumn>…</MainColumn>` the same way.
- If any of these routes' main snippet uses classes that assumed the old scrolling shell (e.g. mail's read pane), verify the wrapper reproduces the old DOM: old prose = `main.overflow-y-auto > div.mx-auto.max-w-[660px].px-8.py-8`; new = `main.flex-col > div.overflow-y-auto.min-h-0.flex-1 > div.mx-auto.max-w-[660px].px-8.py-8`. The extra flex level is the only difference.

- [ ] **Step 5: Verify**

Run (from `frontend/`): `bun run check` and `bun run build` — both clean. `bun run test` — no regressions.

- [ ] **Step 6: Commit**

```bash
git add frontend/src/lib/components/shell/ frontend/src/routes/
git commit -m "refactor(shell): absorb mainVariant into routes via MainColumn

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 6: FileView — format dispatch, viewers, clickable file leaves

**Files:**
- Create: `frontend/src/lib/components/files/raw-url.ts` (+ test `raw-url.test.ts`), `PlainTextView.svelte`, `PdfView.svelte`, `ImageView.svelte`
- Create: `frontend/src/lib/components/views/MarkdownPageView.svelte`, `frontend/src/lib/components/views/FileView.svelte`
- Modify: `frontend/src/lib/shell/nav.ts` (+ `nav.test.ts`), `frontend/src/lib/components/shell/IcmTree.svelte`, `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte`, `frontend/src/lib/editor/tiptap.css`
- Dependency: `bun add pdfjs-dist` (from `frontend/`)

**Interfaces:**
- Consumes: `api.icmPage`, `PageEditorStore`, `PageEditor`/`PageMeta`/`ConflictBanner`/`BacklinksPanel`, `fileLeafKind` from `$lib/components/knowledge/file-leaf` (check its exact signature before use), `recordVisit`, `collectDocLinkPaths`.
- Produces:
  - `rawFileUrl(mountKey: string, path: string): string`
  - `FileView` props: `{ mountKey: string; path: string; onVanished?: () => void }`, instance export `flushPending(): Promise<void>` (delegates to MarkdownPageView; resolves immediately for non-md).
  - `MarkdownPageView` props: `{ mountKey: string; path: string; onVanished?: () => void }`, instance exports `flushPending(): Promise<void>` (the old `flushBeforeMutate` semantics: flush, throw `Error('unsaved_changes')` when still dirty+errored).
  - `IcmTree` gains optional `onSelect?: (sel: { mountKey: string; path: string }) => void` — when present, leaf rows render as buttons calling it (no `<a>` nav, no `EntryMenu`); folder expand/collapse unchanged.
  - `NavTreeItem` gains `ext?: string`; `icmToNav` now emits file leaves (with `ext`) instead of dropping them.
- Tasks 8–9 mount `FileView` in panes; Task 9 re-uses `flushPending` via the route.

- [ ] **Step 1: `raw-url.ts` with test (TDD)**

Test `frontend/src/lib/components/files/raw-url.test.ts`:

```ts
import { describe, expect, it } from 'vitest';
import { rawFileUrl } from './raw-url';

describe('rawFileUrl', () => {
  it('encodes mount and path as single query params', () => {
    expect(rawFileUrl('notes', 'a b/c.pdf')).toBe('/files/raw?mount_key=notes&path=a%20b%2Fc.pdf');
  });
});
```

Implementation (mirrors `image-upload.ts:103`'s existing URL shape exactly):

```ts
/** Display-time URL for a file's raw bytes — same shape `resolveImageSrc` (image-upload.ts) already uses for editor images. */
export function rawFileUrl(mountKey: string, path: string): string {
  return `/files/raw?mount_key=${encodeURIComponent(mountKey)}&path=${encodeURIComponent(path)}`;
}
```

Run `bun run test src/lib/components/files/` — fails first, then passes.

- [ ] **Step 2: Viewers**

`ImageView.svelte`:

```svelte
<script lang="ts">
  import { rawFileUrl } from './raw-url';
  let { mountKey, path }: { mountKey: string; path: string } = $props();
</script>

<img src={rawFileUrl(mountKey, path)} alt={path.split('/').pop()} class="border-paper-hairline max-w-full rounded-md border" />
```

`PlainTextView.svelte` (cap display at 500 KB with a truncation note; fetch failure → in-view message):

```svelte
<script lang="ts">
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  const CAP = 500_000;
  let text = $state<string | null>(null);
  let truncated = $state(false);
  let error = $state<string | null>(null);

  $effect(() => {
    const target = { mountKey, path };
    let cancelled = false;
    text = null;
    error = null;
    truncated = false;
    void (async () => {
      try {
        const res = await fetch(rawFileUrl(target.mountKey, target.path));
        if (!res.ok) throw new Error(String(res.status));
        const body = await res.text();
        if (cancelled) return;
        truncated = body.length > CAP;
        text = truncated ? body.slice(0, CAP) : body;
      } catch {
        if (!cancelled) error = "This file can't be displayed.";
      }
    })();
    return () => {
      cancelled = true;
    };
  });
</script>

{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else if text === null}
  <p class="text-ink-meta text-[13px]">Loading…</p>
{:else}
  {#if truncated}
    <p class="text-ink-meta pb-2 text-[11.5px]">Showing the first 500 KB.</p>
  {/if}
  <pre class="text-ink-body font-mono text-[12px] leading-relaxed whitespace-pre-wrap break-words">{text}</pre>
{/if}
```

`PdfView.svelte` (lazy `pdfjs-dist`; failure → message per spec):

```svelte
<script lang="ts">
  import { rawFileUrl } from './raw-url';

  let { mountKey, path }: { mountKey: string; path: string } = $props();

  let container = $state<HTMLDivElement | null>(null);
  let error = $state<string | null>(null);
  let rendering = $state(true);

  $effect(() => {
    const el = container;
    const url = rawFileUrl(mountKey, path);
    if (!el) return;
    let cancelled = false;
    void (async () => {
      rendering = true;
      error = null;
      try {
        const pdfjs = await import('pdfjs-dist');
        // @ts-expect-error vite ?url asset import has no type declaration
        const worker = await import('pdfjs-dist/build/pdf.worker.min.mjs?url');
        pdfjs.GlobalWorkerOptions.workerSrc = worker.default;
        const doc = await pdfjs.getDocument(url).promise;
        if (cancelled) return;
        el.replaceChildren();
        for (let n = 1; n <= doc.numPages; n++) {
          const page = await doc.getPage(n);
          if (cancelled) return;
          const base = page.getViewport({ scale: 1 });
          const scale = (el.clientWidth || 640) / base.width;
          const viewport = page.getViewport({ scale });
          const ratio = window.devicePixelRatio || 1;
          const canvas = document.createElement('canvas');
          canvas.width = viewport.width * ratio;
          canvas.height = viewport.height * ratio;
          canvas.style.width = `${viewport.width}px`;
          canvas.style.height = `${viewport.height}px`;
          canvas.className = 'mb-3 rounded-md border border-paper-hairline';
          el.appendChild(canvas);
          const ctx = canvas.getContext('2d');
          if (!ctx) throw new Error('no 2d context');
          ctx.scale(ratio, ratio);
          await page.render({ canvasContext: ctx, viewport }).promise;
        }
      } catch {
        if (!cancelled) error = "This PDF can't be displayed. Open it in your file manager instead.";
      } finally {
        if (!cancelled) rendering = false;
      }
    })();
    return () => {
      cancelled = true;
    };
  });
</script>

{#if error}
  <p class="text-ink-meta text-[13px]">{error}</p>
{:else}
  {#if rendering}
    <p class="text-ink-meta pb-2 text-[13px]">Rendering…</p>
  {/if}
  <div bind:this={container}></div>
{/if}
```

Run `bun add pdfjs-dist` first. If the exact worker asset path differs in the installed version (check `frontend/node_modules/pdfjs-dist/build/`), use the `.mjs` worker file that exists there.

- [ ] **Step 3: Extract `MarkdownPageView.svelte`**

Create `frontend/src/lib/components/views/MarkdownPageView.svelte` by MOVING, from `frontend/src/routes/knowledge/[...path]/+page.svelte`, everything that concerns one open `.md` page. Concretely:

- Props/replacements: `mountKey` and `decodedPath` become props `{ mountKey, path, onVanished }` — replace every `decodedPath` read with `path`, every `goto('/knowledge')` in `runExternalCheckLoop` with `onVanished?.()`.
- Move these script blocks verbatim (current line refs): `PageContent`/`content`/`loadFailed`/`loading`/`loadedPath`/`store`/`editorRef`/`viewMode`/`rawText`/`lastFetch`/`editorHash`/`tokenEstimate` state (lines 134–167), `refreshDangling` (169–181), `loadPage` (183–215) and its trigger effect (217–221) — the trigger becomes `$effect(() => { if (path !== loadedPath) void loadPage(mountKey, path); })`, dangling effects (228–243), `applyReload` (245–263), external-check loop + effects (280–337), `showRaw`/`showFriendly`/`toggleView` (339–373), `beforeNavigate`/`onDestroy` flushes (381–387), `parentLabel` (111–114).
- Move the ENTIRE `pageArticle` snippet markup (lines 479–546) as the component's template, plus the loading/failed branches that gate it (lines 452–457): `Loading…` / `This page doesn't exist anymore.`
- Move the imports those blocks need (PageEditor, PageMeta, ConflictBanner, PageEditorStore, BacklinksPanel, SegmentedControl, api/IcmPageData, recordVisit, collectDocLinkPaths). Note: `parentPath` from `./parent-path` is NOT needed here — `parentLabel` computes from plain segment math; `parentPath` is only used by `listContext`, which stays in the route. `parent-path.ts` does not move.
- Expose the flush contract:

```ts
export async function flushPending(): Promise<void> {
  if (!store) return;
  await store.flush();
  if (store.state === 'dirty' && store.error) {
    throw new Error('unsaved_changes');
  }
}
```

- [ ] **Step 4: Create `FileView.svelte`**

```svelte
<script lang="ts">
  // Format dispatch for one file (side-panes pass): .md gets the full page
  // editor; known binary formats get their own viewer; everything else is
  // read-only text. Usable both as a route primary and inside PaneHost.
  import MarkdownPageView from './MarkdownPageView.svelte';
  import PlainTextView from '$lib/components/files/PlainTextView.svelte';
  import PdfView from '$lib/components/files/PdfView.svelte';
  import ImageView from '$lib/components/files/ImageView.svelte';
  import { fileLeafKind } from '$lib/components/knowledge/file-leaf';

  let { mountKey, path, onVanished }: { mountKey: string; path: string; onVanished?: () => void } = $props();

  const ext = $derived('.' + (path.split('.').pop() ?? '').toLowerCase());
  const format = $derived.by((): 'md' | 'image' | 'pdf' | 'text' => {
    if (path.endsWith('.md')) return 'md';
    const kind = fileLeafKind(ext);
    if (kind === 'image') return 'image';
    if (kind === 'pdf') return 'pdf';
    return 'text';
  });

  let mdRef = $state<MarkdownPageView | null>(null);

  export async function flushPending(): Promise<void> {
    await mdRef?.flushPending();
  }
</script>

{#if format === 'md'}
  <MarkdownPageView bind:this={mdRef} {mountKey} {path} {onVanished} />
{:else}
  <article class="mx-auto flex w-full max-w-[596px] flex-col gap-3">
    <header class="flex flex-col gap-1.5">
      <p class="text-overline">{path.split('/').slice(-2, -1)[0] ?? 'Files'}</p>
      <p class="text-ink-meta font-mono text-[11.5px]">{path}</p>
    </header>
    {#if format === 'image'}
      <ImageView {mountKey} {path} />
    {:else if format === 'pdf'}
      <PdfView {mountKey} {path} />
    {:else}
      <PlainTextView {mountKey} {path} />
    {/if}
  </article>
{/if}
```

(Verify `fileLeafKind`'s actual signature/return values in `frontend/src/lib/components/knowledge/file-leaf.ts` first and adapt the dispatch — the values above assume `'image' | 'pdf' | …`.)

- [ ] **Step 5: Make file leaves navigable — `nav.ts` + `IcmTree.svelte`**

`nav.ts`: add `ext?: string` to `NavTreeItem`; replace the `if (n.type === 'file') { return []; }` branch of `icmToNav` (lines 141–143) with:

```ts
    // Side-panes pass: file leaves are navigable now — FileView renders
    // non-.md formats (plain text / pdf.js / image), so the old "visible but
    // never clickable" special case is gone.
    if (n.type === 'file') {
      return [{ label: n.name, href: knowledgeHref(n.mountKey, n.path), path: n.path, mountKey: n.mountKey, ext: n.ext }];
    }
```

Update `nav.test.ts`: the existing assertion that file leaves are dropped flips to asserting they are emitted with `ext` + href. Run `bun run test src/lib/shell/nav.test.ts` (fail → fix → pass).

`IcmTree.svelte`: add to props:

```ts
    /**
     * Selection mode (side-panes pass): when set, leaf rows call this
     * instead of navigating (used by popover pickers); EntryMenu is hidden.
     * Folder expand/collapse behaves identically in both modes.
     */
    onSelect?: (sel: { mountKey: string; path: string }) => void;
```

Thread `{onSelect}` through the recursive `<IcmTree …/>` call (line 92). Replace the leaf branch (lines 98–119) with:

```svelte
      {:else}
        <div class="group relative">
          {#if onSelect}
            <button
              type="button"
              onclick={() => onSelect?.({ mountKey: node.mountKey, path: node.path })}
              class="hover:bg-paper-pill text-ink-secondary flex w-full items-center gap-1 rounded-md py-[3px] pr-2 pl-2 text-left text-[12.5px] transition-colors"
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.ext}
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em] uppercase">{node.ext.slice(1)}</span>
              {/if}
            </button>
          {:else}
            <a
              href={node.href}
              aria-current={activePath === node.href ? 'page' : undefined}
              class={[
                'flex items-center gap-1 rounded-md py-[3px] pr-9 pl-2 text-[12.5px] transition-colors hover:bg-paper-pill',
                activePath === node.href ? 'bg-paper-tree-active text-ink-heading' : 'text-ink-secondary'
              ]}
            >
              <span class="min-w-0 flex-1 truncate">{node.label}</span>
              {#if node.ext}
                <span class="text-ink-meta text-[10px] font-semibold tracking-[0.04em] uppercase">{node.ext.slice(1)}</span>
              {/if}
            </a>
            <EntryMenu
              mountKey={node.mountKey}
              path={node.path}
              name={node.label}
              isFolder={false}
              class="absolute top-1/2 right-0.5 -translate-y-1/2"
              onBeforeMutate={activePath === node.href ? onBeforeMutate : undefined}
            />
          {/if}
        </div>
      {/if}
```

Also hide the folder rows' `EntryMenu` in select mode: wrap the folder `EntryMenu` (lines 78–85) in `{#if !onSelect}…{/if}`.

- [ ] **Step 6: Rewire the knowledge routes**

`knowledge/[...path]/+page.svelte`:
- Remove everything moved to `MarkdownPageView` (script + `pageArticle` snippet + loading/failed page branches + now-unused imports). Keep: params parsing, ensure/tree effects, `listContext`, `treeNav`, list pane, `NewEntryDialog`, `flushBeforeMutate` — which becomes:

```ts
  let fileViewRef = $state<FileView | null>(null);

  async function flushBeforeMutate(): Promise<void> {
    await fileViewRef?.flushPending();
  }
```

- Main branch logic becomes (`hasExtension` = `/\.[^/]+$/.test(decodedPath.split('/').pop() ?? '')`):

```svelte
  {#snippet main()}
    <MainColumn wide>
      {#if node?.type === 'folder'}
        <div class="mx-auto w-full max-w-[596px]">
          <PageHeader title={node.name} subtitle="Pick a page from the list to read it." />
        </div>
      {:else if node || hasExtension}
        <FileView bind:this={fileViewRef} {mountKey} path={decodedPath} onVanished={() => void goto('/knowledge')} />
      {:else if !icmStore.loaded || !ensureSettled}
        <div class="mx-auto flex w-full max-w-[596px] flex-col gap-3" data-testid="knowledge-loading-skeleton">
          <Skeleton class="h-6 w-1/3" />
          <Skeleton class="h-4 w-2/3" />
          <Skeleton class="h-4 w-1/2" />
        </div>
      {:else}
        <p class="mx-auto w-full max-w-[596px] text-ink-body text-[13.5px]">This page doesn't exist anymore.</p>
      {/if}
    </MainColumn>
  {/snippet}
```

- Delete the `topLevelFileLeaves` block from the list pane (lines 100, 425–443) and its icon imports — file leaves now render inside `IcmTree` itself.

`knowledge/+page.svelte` (index): delete its equivalent file-leaf rows block and unused imports (`fileLeafKind`/`fileLeafLabel`/icon imports) — the tree now covers them.

- [ ] **Step 7: Width-aware tiptap caps**

In `frontend/src/lib/editor/tiptap.css`: line 89 `max-width: 596px;` → `max-width: min(596px, 100%);` and line 107 `min-width: 596px;` → `min-width: min(596px, 100%);` (read the surrounding rules first; apply to exactly the per-block prose cap and the table min-width rule the 596 values belong to).

- [ ] **Step 8: Verify**

`bun run test` (nav + raw-url + suite) — PASS. `bun run check` + `bun run build` — clean. Note for the reviewer: `/knowledge` file leaves (e.g. a PDF) are expected to be clickable now and open the new viewers.

- [ ] **Step 9: Commit**

```bash
git add frontend/src frontend/package.json frontend/bun.lock
git commit -m "feat(files): FileView with per-format viewers; navigable file leaves

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 7: ChatView + SessionHeader extraction

**Files:**
- Create: `frontend/src/lib/components/views/ChatView.svelte`, `frontend/src/lib/components/agent/SessionHeader.svelte`
- Modify: `frontend/src/routes/chat/+page.svelte`, `frontend/src/lib/components/agent/index.ts` (barrel, if SessionHeader belongs there)

**Interfaces:**
- Consumes: `AgentSessionStore`, `takeInitialPrompt`/`setInitialPrompt`, `sessionsListStore` (module singleton in `sessions-list.svelte.ts`), `recentSessionsStore`, `mountsStore`, `workspaceStore`, `api` (`archiveAgentSession`, `resumeAgentSession`, `createAgentSession`), `Transcript`/`PlanBar`/`UsageLine`/`Composer`/`DoctorPanel`, `sessionInfoTitle`, `icmStore` + `icmToNav` + `IcmTree` (+ its Task 6 `onSelect`), `Popover` (Task 4), `PaneContext` shape defined here and reused by Task 8.
- Produces:
  - `export type PaneContext = { placement: 'primary' | 'pane'; openFile?: (sel: { mountKey: string; path: string }) => void; sessionCreated?: (id: string) => void; onArchived?: () => void; }` — define in `frontend/src/lib/panes/pane-route.ts`? **No** — define it in `frontend/src/lib/panes/context.ts` (new tiny file, pure types) so both views and PaneHost import it without circularity.
  - `ChatView` props: `{ descriptor: ChatPaneDescriptor | ChatNewPaneDescriptor; context: PaneContext }` (types from `pane-route.ts`).
  - `SessionHeader` props: `{ icmName: string | null; mountKey: string | null; ended: boolean; archiving: boolean; onArchive?: () => void; onOpenFile?: (sel: { mountKey: string; path: string }) => void }`.
  - Chat route renders `<ChatView descriptor={{kind:'chat', sessionId}} context={{placement:'primary', openFile}}/>` — `openFile` arrives in Task 8 (this task passes `{ placement: 'primary' }` only).

- [ ] **Step 1: Create `frontend/src/lib/panes/context.ts`**

```ts
import type { PaneDescriptor } from './pane-route';

/**
 * What a host (route or PaneHost) provides to a mounted view (side-panes
 * pass). Views must tolerate every callback being absent.
 */
export type PaneContext = {
  placement: 'primary' | 'pane';
  /** Open a file somewhere sensible for this host (side pane on /chat; primary navigation on /knowledge). */
  openFile?: (sel: { mountKey: string; path: string }) => void;
  /** A chat-new view created its session — host rewrites its descriptor to `chat:<id>`. */
  sessionCreated?: (id: string) => void;
  /** The view's subject was archived/removed — host should close/navigate away. */
  onArchived?: () => void;
};

export type { PaneDescriptor };
```

- [ ] **Step 2: Create `SessionHeader.svelte`**

Extract the inline header (chat route lines 468–492) plus the new popover tree:

```svelte
<script lang="ts">
  // The chat session's header line (extracted from the chat route,
  // side-panes pass): which ICM the session works in, an archive affordance
  // when ended, and — when the host can open files — the folder name becomes
  // a popover file tree for opening a file beside the chat.
  import Folder from '@lucide/svelte/icons/folder';
  import Archive from '@lucide/svelte/icons/archive';
  import ChevronDown from '@lucide/svelte/icons/chevron-down';
  import * as Popover from '$lib/components/ui/popover';
  import { IcmTree } from '$lib/components/shell';
  import { icmStore } from '$lib/stores/icm.svelte';
  import { icmToNav } from '$lib/shell/nav';

  let {
    icmName,
    mountKey,
    ended,
    archiving,
    onArchive,
    onOpenFile
  }: {
    icmName: string | null;
    mountKey: string | null;
    ended: boolean;
    archiving: boolean;
    onArchive?: () => void;
    onOpenFile?: (sel: { mountKey: string; path: string }) => void;
  } = $props();

  let treeOpen = $state(false);
  const treeNav = $derived(icmToNav(icmStore.groups.find((g) => g.mount === mountKey)?.tree ?? []));
  const canBrowse = $derived(Boolean(onOpenFile && mountKey));
</script>

{#if icmName || ended}
  <div class="border-paper-hairline flex items-center gap-1.5 border-b px-4 pb-2">
    {#if icmName}
      {#if canBrowse}
        <Popover.Root bind:open={treeOpen}>
          <Popover.Trigger
            class="hover:bg-paper-pill -mx-1 flex items-center gap-1.5 rounded-md px-1 py-0.5 transition-colors"
          >
            <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
            <span class="text-ink-meta text-[12px]">
              Working in <span class="text-ink-secondary font-medium">{icmName}</span>
            </span>
            <ChevronDown class="text-ink-meta size-3 shrink-0" strokeWidth={1.5} aria-hidden="true" />
          </Popover.Trigger>
          <Popover.Content class="max-h-96 overflow-y-auto p-2">
            {#if treeNav.length}
              <IcmTree
                nodes={treeNav}
                onSelect={(sel) => {
                  treeOpen = false;
                  onOpenFile?.(sel);
                }}
              />
            {:else}
              <p class="text-ink-meta px-2 py-1 text-[12px]">No files yet.</p>
            {/if}
          </Popover.Content>
        </Popover.Root>
      {:else}
        <Folder class="text-ink-meta size-3.5 shrink-0" strokeWidth={1.5} aria-hidden="true" />
        <span class="text-ink-meta text-[12px]">
          Working in <span class="text-ink-secondary font-medium">{icmName}</span>
        </span>
      {/if}
    {/if}
    <span class="min-w-0 flex-1" aria-hidden="true"></span>
    {#if ended && onArchive}
      <button
        type="button"
        onclick={onArchive}
        disabled={archiving}
        class="text-ink-meta hover:text-ink-heading flex shrink-0 items-center gap-1 text-[12px] transition-colors"
      >
        <Archive class="size-3.5" strokeWidth={1.5} aria-hidden="true" />
        {archiving ? 'Archiving…' : 'Archive'}
      </button>
    {/if}
  </div>
{/if}
```

Note: the popover tree needs the mount's tree loaded — add in ChatView (not here): `$effect(() => { if (mountKey && !icmStore.groups.some((g) => g.mount === mountKey)) void icmStore.refetch(); })` — verify `icmStore`'s actual API for loading one mount (`refetch()` loads all top levels; folder expansion inside the popover already lazy-loads via `IcmTree`'s own `loadDir` calls).

- [ ] **Step 3: Create `ChatView.svelte`**

Move from `frontend/src/routes/chat/+page.svelte` into `ChatView` (props `{ descriptor, context }`):

- The store lifecycle effect (lines 80–99) — keyed on `descriptor.kind === 'chat' ? descriptor.sessionId : null` instead of `selectedId`.
- Status/title transition effects (lines 118–169) — replace `sessionsList.refresh()` with the singleton `sessionsListStore.refresh()`.
- Dock singletons `planItem`/`usageItem`/`configItems` (234–236); `ended`/`starting`/`sessionDoctor` derivations (254–267); resume machinery (275–308); scroll pinning (343–363, with the "different session resets pinned" effect keyed on the sessionId prop).
- Archive of the OPEN session (from `archiveSession`, lines 315–334): keep a local `archiving: boolean` + `archiveError`; on success call `void sessionsListStore.refresh(); void recentSessionsStore.refresh(); context.onArchived?.();` (no `goto` here — hosts decide).
- ICM identity: 

```ts
  const sessionId = $derived(descriptor.kind === 'chat' ? descriptor.sessionId : null);
  const summary = $derived.by(() => {
    if (!sessionId) return undefined;
    return (
      sessionsListStore.sessions.find((s) => s.id === sessionId) ??
      recentSessionsStore.groups.flatMap((g) => g.sessions).find((s) => s.id === sessionId)
    );
  });
  const openMountKey = $derived.by(() => {
    if (descriptor.kind === 'chat-new') return descriptor.mountKey;
    if (summary?.icmMount) return summary.icmMount;
    return recentSessionsStore.groups.find((g) => g.sessions.some((s) => s.id === sessionId))?.mountKey ?? null;
  });
  const openIcmName = $derived.by(() => {
    if (summary?.icmName) return summary.icmName;
    return recentSessionsStore.groups.find((g) => g.sessions.some((s) => s.id === sessionId))?.icmName ?? null;
  });
```

  plus `onMount(() => { if (!sessionsListStore.loaded) void sessionsListStore.refresh(); })`.
- New-session mode (`descriptor.kind === 'chat-new'`): no store; render the transcript area as a short empty state ("New session in <icm name from mountsStore>") above a `Composer` whose `onSend` runs:

```ts
  let createError = $state<string | null>(null);

  async function createAndPrompt(text: string): Promise<void> {
    if (descriptor.kind !== 'chat-new') return;
    createError = null;
    const result = await api.createAgentSession(descriptor.mountKey, workspaceStore.generation ?? 0);
    if (!result.ok) {
      createError =
        result.error === 'harness_unavailable'
          ? "The assistant isn't ready — open Agent settings (the gear in the sidebar) and run the checks."
          : 'The session could not be started. Please try again.';
      return;
    }
    const data = result.data as { id: string };
    setInitialPrompt(data.id, text);
    void sessionsListStore.refresh();
    void recentSessionsStore.refresh();
    context.sessionCreated?.(data.id);
  }
```

- Template: the current main-pane session branch (route lines 460–522) minus the inline header (replaced by `<SessionHeader icmName={openIcmName} mountKey={openMountKey} {ended} {archiving} onArchive={…} onOpenFile={context.openFile ? (sel) => context.openFile?.(sel) : undefined} />`), wrapped exactly as today in `<div class="mx-auto flex min-h-0 w-full max-w-[660px] flex-1 flex-col px-4 pt-3">`. Transcript gets `onOpenFile` threaded (see Task 8 — for now pass nothing; Task 8 adds the prop).
- Keep `sessionDoctor` → `DoctorPanel` branch inside ChatView.

- [ ] **Step 4: Slim the chat route**

`frontend/src/routes/chat/+page.svelte` keeps: `sessionsList` — replace the local `new SessionsListStore(api)` with the module singleton `sessionsListStore` (all-sessions pane + `startSession` refresh call sites), `?all=1` list pane + its per-row archive, `startSession`/`primaryMountKey`/`doctorOverride`/`startError`/empty state, `relativeTime`/`sessionTitle` helpers. Everything moved above is deleted. The main snippet becomes:

```svelte
  {#snippet main()}
    {#if doctorOverride}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8"><DoctorPanel /></div>
    {:else if !selectedId}
      <!-- unchanged empty state -->
    {:else}
      <ChatView descriptor={{ kind: 'chat', sessionId: selectedId }} context={{ placement: 'primary' }} />
    {/if}
  {/snippet}
```

`doctorOverride` reset on selection change stays in the route (its `$effect` watching `selectedId`). The route-level `archiveError`/`archiving` map stays for the LIST rows only; after archiving the OPEN session from ChatView, the route handles navigation via `context.onArchived` — wire `context={{ placement: 'primary', onArchived: () => void goto(showAllPane ? '/chat?all=1' : '/chat') }}`.

- [ ] **Step 5: Verify**

`bun run check`, `bun run build`, `bun run test` — all clean. Chat behavior must be unchanged (session open/stream/resume/archive, all-sessions pane), PLUS: the header folder name now opens the popover tree; clicking a file does nothing yet (no `openFile` in context until Task 8) — acceptable interim; the popover only renders when `context.openFile` exists, so actually **nothing changes visibly** in this task.

- [ ] **Step 6: Commit**

```bash
git add frontend/src
git commit -m "refactor(chat): extract ChatView + SessionHeader as pane-mountable views

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 8: PaneHost + registry + /chat integration

**Files:**
- Create: `frontend/src/lib/panes/registry.ts`, `frontend/src/lib/components/panes/PaneHost.svelte`, `frontend/src/lib/components/panes/FilePaneAdapter.svelte`
- Modify: `frontend/src/routes/chat/+page.svelte`, `frontend/src/lib/components/agent/ToolCallCard.svelte`, `frontend/src/lib/components/agent/Transcript.svelte`, `frontend/src/lib/components/views/ChatView.svelte` (thread `onOpenFile` to Transcript)
- Dependency: `bun add paneforge` (from `frontend/`)

**Interfaces:**
- Consumes: Task 3 codec/persistence, Task 6 `FileView`, Task 7 `ChatView`/`PaneContext`, Task 2 `toolLocations`, paneforge (`PaneGroup`, `Pane`, `PaneResizer` — check the installed version's README in `frontend/node_modules/paneforge/` for exact prop names before writing PaneHost; the shapes below assume `defaultSize`/`minSize` on `Pane` and `onLayoutChange` on `PaneGroup`).
- Produces:
  - `registry.ts`: `export const paneComponents: Record<PaneDescriptor['kind'], Component<{ descriptor: PaneDescriptor; context: PaneContext }>>` mapping `file → FileView`-adapter, `chat`/`chat-new` → ChatView. Because `FileView` takes `{mountKey, path}` props (not descriptor), registry wraps it with a 5-line adapter component `FilePaneAdapter.svelte` in the same folder.
  - `PaneHost` props: `{ primary: Snippet; primaryDescriptor?: PaneDescriptor | null; pane?: PaneDescriptor | null; paneContext: PaneContext; onClose: () => void; onPromote: (d: PaneDescriptor) => void }`.
  - Chat route: tool chips + header tree open `?pane=file:…`; close/promote work; split persists.

- [ ] **Step 1: Install paneforge and read its API**

`bun add paneforge`, then read `frontend/node_modules/paneforge/README.md` (or `dist/*.d.ts`) and note the exact component/prop names. Adjust Step 3's code to the real API.

- [ ] **Step 2: Registry + adapter**

`frontend/src/lib/components/panes/FilePaneAdapter.svelte`:

```svelte
<script lang="ts">
  import FileView from '$lib/components/views/FileView.svelte';
  import type { PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';

  let { descriptor, context }: { descriptor: PaneDescriptor; context: PaneContext } = $props();
</script>

{#if descriptor.kind === 'file'}
  <div class="min-h-0 flex-1 overflow-y-auto px-6 py-6">
    <FileView mountKey={descriptor.mountKey} path={descriptor.path} onVanished={context.onArchived} />
  </div>
{/if}
```

`frontend/src/lib/panes/registry.ts`:

```ts
/**
 * kind -> view component for PaneHost (side-panes pass). THE one place to
 * extend when a new view becomes pane-mountable (mail, calendar, …): add a
 * descriptor variant in pane-route.ts, a component here, an entry point in
 * the owning route.
 */
import type { Component } from 'svelte';
import type { PaneDescriptor } from './pane-route';
import type { PaneContext } from './context';
import ChatView from '$lib/components/views/ChatView.svelte';
import FilePaneAdapter from '$lib/components/panes/FilePaneAdapter.svelte';

type PaneViewComponent = Component<{ descriptor: PaneDescriptor; context: PaneContext }>;

export const paneComponents: Record<PaneDescriptor['kind'], PaneViewComponent> = {
  file: FilePaneAdapter as unknown as PaneViewComponent,
  chat: ChatView as unknown as PaneViewComponent,
  'chat-new': ChatView as unknown as PaneViewComponent
};
```

(ChatView's props type is narrower than the registry's uniform contract — the `as unknown as` casts are the documented cost of the uniform map; ChatView must guard internally on `descriptor.kind`, which it already does.)

- [ ] **Step 3: `PaneHost.svelte`**

```svelte
<script lang="ts">
  // Renders the route's primary view alone, or split with ONE side pane
  // (side-panes pass; deliberately not a tiling manager). The pane slot is
  // registry-driven; chrome = title, promote ("open as full view"), close.
  import { PaneGroup, Pane, PaneResizer } from 'paneforge';
  import type { Snippet } from 'svelte';
  import { panesEqual, paneTitle, type PaneDescriptor } from '$lib/panes/pane-route';
  import type { PaneContext } from '$lib/panes/context';
  import { paneComponents } from '$lib/panes/registry';
  import { loadPaneSplit, savePaneSplit } from '$lib/panes/pane-split';
  import X from '@lucide/svelte/icons/x';
  import Maximize2 from '@lucide/svelte/icons/maximize-2';

  let {
    primary,
    primaryDescriptor = null,
    pane = null,
    paneContext,
    onClose,
    onPromote
  }: {
    primary: Snippet;
    primaryDescriptor?: PaneDescriptor | null;
    pane?: PaneDescriptor | null;
    paneContext: PaneContext;
    onClose: () => void;
    onPromote: (d: PaneDescriptor) => void;
  } = $props();

  // A pane duplicating the primary view renders nothing (pane-route doc).
  const active = $derived(pane && !panesEqual(pane, primaryDescriptor) ? pane : null);
  const initialSplit = loadPaneSplit();

  function onLayoutChange(layout: number[]): void {
    if (layout.length === 2) savePaneSplit(layout[0]);
  }
</script>

{#if active}
  {@const PaneView = paneComponents[active.kind]}
  <PaneGroup direction="horizontal" class="min-h-0 flex-1" {onLayoutChange}>
    <Pane defaultSize={initialSplit} minSize={30} class="flex min-h-0 min-w-0 flex-col">
      {@render primary()}
    </Pane>
    <PaneResizer
      class="bg-paper-hairline hover:bg-paper-chip-border w-[3px] shrink-0 cursor-col-resize transition-colors"
    />
    <Pane minSize={30} class="bg-paper-panel flex min-h-0 min-w-0 flex-col">
      <div class="border-paper-hairline flex shrink-0 items-center gap-2 border-b px-3 py-1.5">
        <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12px] font-medium">{paneTitle(active)}</span>
        <button
          type="button"
          title="Open as full view"
          aria-label="Open as full view"
          onclick={() => active && onPromote(active)}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-6 items-center justify-center rounded-md transition-colors"
        >
          <Maximize2 class="size-3.5" strokeWidth={1.5} />
        </button>
        <button
          type="button"
          title="Close pane"
          aria-label="Close pane"
          onclick={onClose}
          class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-6 items-center justify-center rounded-md transition-colors"
        >
          <X class="size-3.5" strokeWidth={1.5} />
        </button>
      </div>
      {#key active}
        <PaneView descriptor={active} context={paneContext} />
      {/key}
    </Pane>
  </PaneGroup>
{:else}
  {@render primary()}
{/if}
```

(`{#key active}` forces a clean remount when the pane's identity changes — a `chat-new` → `chat:<id>` rewrite deliberately remounts and the new ChatView fires the stashed initial prompt.) **Sanity-check paneforge's real prop names in Step 1 and adapt.**

- [ ] **Step 4: Tool chips**

`ToolCallCard.svelte`: add prop `onOpenFile?: (relPath: string) => void`; derive locations; render a chip row between header and body:

```ts
  import { asString, asPresentString, toolDiff, diffLines, toolLocations } from './item-shapes';
  // …
  let { item, onOpenFile }: { item: AcpItemLike; onOpenFile?: (relPath: string) => void } = $props();

  const locations = $derived.by(() => {
    const seen = new Set<string>();
    return toolLocations(item).filter((l) => {
      const key = l.relPath ?? l.path;
      if (seen.has(key)) return false;
      seen.add(key);
      return true;
    });
  });
```

```svelte
  {#if locations.length}
    <div class="flex flex-wrap gap-1 px-3 pb-2">
      {#each locations as loc (loc.relPath ?? loc.path)}
        {#if loc.relPath && onOpenFile}
          <button
            type="button"
            onclick={() => onOpenFile?.(loc.relPath!)}
            class="border-paper-chip-border hover:bg-paper-pill text-ink-secondary rounded-md border px-1.5 py-0.5 font-mono text-[11px] transition-colors"
          >
            {loc.relPath}{loc.line !== undefined ? `:${loc.line}` : ''}
          </button>
        {:else}
          <span class="text-ink-meta font-mono text-[11px]">{loc.relPath ?? loc.path}</span>
        {/if}
      {/each}
    </div>
  {/if}
```

(SECURITY note in the file already covers this: paths are agent-produced strings — interpolation only, never `{@html}`; the click handler only feeds the string into the pane-route codec.)

`Transcript.svelte`: add `onOpenFile?: (relPath: string) => void` to props; pass `{onOpenFile}` to `<ToolCallCard {item} {onOpenFile} />`.

`ChatView.svelte`: thread it — `<Transcript {store} onOpenFile={openMountKey && context.openFile ? (relPath) => context.openFile?.({ mountKey: openMountKey, path: relPath }) : undefined} />`.

- [ ] **Step 5: Chat route integration**

In `frontend/src/routes/chat/+page.svelte`:

```ts
  import { parsePaneParam, withPaneParam, promoteHref, type PaneDescriptor } from '$lib/panes/pane-route';
  import PaneHost from '$lib/components/panes/PaneHost.svelte';

  const paneDescriptor = $derived(parsePaneParam(page.url.searchParams.get('pane')));
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    selectedId ? { kind: 'chat', sessionId: selectedId } : null
  );

  function openFilePane(sel: { mountKey: string; path: string }): void {
    void goto(withPaneParam(page.url, { kind: 'file', ...sel }), { keepFocus: true, noScroll: true });
  }

  function closePane(): void {
    void goto(withPaneParam(page.url, null), { keepFocus: true, noScroll: true });
  }

  function promotePane(d: PaneDescriptor): void {
    void goto(promoteHref(d));
  }
```

Main snippet becomes:

```svelte
  {#snippet main()}
    {#if doctorOverride}
      <div class="mx-auto w-full max-w-[660px] overflow-y-auto px-8 py-8"><DoctorPanel /></div>
    {:else}
      <PaneHost
        {primaryDescriptor}
        pane={paneDescriptor}
        paneContext={{ placement: 'pane', onArchived: closePane }}
        onClose={closePane}
        onPromote={promotePane}
      >
        {#snippet primary()}
          {#if !selectedId}
            <!-- unchanged empty state -->
          {:else}
            <ChatView
              descriptor={{ kind: 'chat', sessionId: selectedId }}
              context={{
                placement: 'primary',
                openFile: openFilePane,
                onArchived: () => void goto(showAllPane ? '/chat?all=1' : '/chat')
              }}
            />
          {/if}
        {/snippet}
      </PaneHost>
    {/if}
  {/snippet}
```

- [ ] **Step 6: Verify**

`bun run test`, `bun run check`, `bun run build` — clean. Functional (manual or via dev preview): open a chat, click the folder header → tree popover → click a `.md` → file pane opens right, editable; resize persists across reload; ✕ closes (URL param drops); promote navigates to `/knowledge/...`; a tool card that read a file shows a clickable chip (requires a live agent turn — if no live harness is available, verify chips via the transcript of a past session where diff paths exist, and rely on Task 1's unit tests for locations).

- [ ] **Step 7: Commit**

```bash
git add frontend/src frontend/package.json frontend/bun.lock
git commit -m "feat(panes): PaneHost + registry; file panes on /chat via chips and header tree

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

### Task 9: /knowledge integration — chat panes + session picker

**Files:**
- Create: `frontend/src/lib/components/knowledge/SessionPickerPopover.svelte`
- Modify: `frontend/src/routes/knowledge/[...path]/+page.svelte`, `frontend/src/routes/knowledge/+page.svelte`

**Interfaces:**
- Consumes: Tasks 3/7/8 (`parsePaneParam`, `withPaneParam`, `promoteHref`, `PaneHost`, `PaneContext`), `recentSessionsStore.sessionsFor(mountKey)`, `knowledgeHref`.
- Produces: `SessionPickerPopover` props: `{ mountKey: string; onOpenSession: (id: string) => void; onNewSession: () => void }`. Both knowledge routes gain the picker (in the ListPane `action` area, next to `NewEntryButton` — one placement that exists in every route state; this refines the spec's "PageHeader" wording) and render side panes via PaneHost.

- [ ] **Step 1: `SessionPickerPopover.svelte`**

```svelte
<script lang="ts">
  // Mount-scoped session picker (side-panes pass): the reverse-combo entry
  // point — open a recent session (or a new one) beside the file you're
  // reading. Recent list = the same store the sidebar's project groups use.
  import MessageSquare from '@lucide/svelte/icons/message-square';
  import * as Popover from '$lib/components/ui/popover';
  import { recentSessionsStore } from '$lib/stores/recent-sessions.svelte';

  let {
    mountKey,
    onOpenSession,
    onNewSession
  }: {
    mountKey: string;
    onOpenSession: (id: string) => void;
    onNewSession: () => void;
  } = $props();

  let open = $state(false);
  const sessions = $derived(recentSessionsStore.sessionsFor(mountKey));

  function title(s: { title?: string | null; kind: string }): string {
    if (s.title && s.title.trim().length > 0) return s.title;
    return s.kind === 'workflow' ? 'Workflow run' : 'Chat session';
  }
</script>

<Popover.Root bind:open>
  <Popover.Trigger
    title="Open a session beside this file"
    aria-label="Open a session beside this file"
    class="text-ink-meta hover:text-ink-heading hover:bg-paper-pill flex size-7 items-center justify-center rounded-md transition-colors"
  >
    <MessageSquare class="size-4" strokeWidth={1.5} />
  </Popover.Trigger>
  <Popover.Content class="p-1.5">
    <button
      type="button"
      onclick={() => {
        open = false;
        onNewSession();
      }}
      class="hover:bg-paper-pill text-ink-heading w-full rounded-md px-2 py-1.5 text-left text-[12.5px] [font-weight:650]"
    >
      New session
    </button>
    {#if sessions.length}
      <p class="text-overline px-2 pt-2 pb-1">Recent</p>
      <ul class="flex flex-col">
        {#each sessions as session (session.id)}
          <li>
            <button
              type="button"
              onclick={() => {
                open = false;
                onOpenSession(session.id);
              }}
              class="hover:bg-paper-pill flex w-full items-center gap-1.5 rounded-md px-2 py-1.5 text-left"
            >
              {#if session.live}
                <span class="bg-act-dot size-1.5 shrink-0 rounded-full" aria-hidden="true"></span>
              {/if}
              <span class="text-ink-secondary min-w-0 flex-1 truncate text-[12.5px]">{title(session)}</span>
            </button>
          </li>
        {/each}
      </ul>
    {/if}
  </Popover.Content>
</Popover.Root>
```

- [ ] **Step 2: `/knowledge/[...path]` integration**

```ts
  import PaneHost from '$lib/components/panes/PaneHost.svelte';
  import SessionPickerPopover from '$lib/components/knowledge/SessionPickerPopover.svelte';
  import { parsePaneParam, withPaneParam, promoteHref, type PaneDescriptor } from '$lib/panes/pane-route';

  const paneDescriptor = $derived(parsePaneParam(page.url.searchParams.get('pane')));
  const primaryDescriptor = $derived<PaneDescriptor | null>(
    decodedPath ? { kind: 'file', mountKey, path: decodedPath } : null
  );

  function openSessionPane(id: string): void {
    void goto(withPaneParam(page.url, { kind: 'chat', sessionId: id }), { keepFocus: true, noScroll: true });
  }

  function openNewSessionPane(): void {
    void goto(withPaneParam(page.url, { kind: 'chat-new', mountKey }), { keepFocus: true, noScroll: true });
  }

  function closePane(): void {
    void goto(withPaneParam(page.url, null), { keepFocus: true, noScroll: true });
  }

  function promotePane(d: PaneDescriptor): void {
    void goto(promoteHref(d));
  }

  /** A chat pane opening a file navigates the PRIMARY (the pane stays). */
  function openFileAsPrimary(sel: { mountKey: string; path: string }): void {
    const url = new URL(knowledgeHref(sel.mountKey, sel.path), page.url.origin);
    const pane = page.url.searchParams.get('pane');
    if (pane) url.searchParams.set('pane', pane);
    void goto(url.pathname + url.search, { keepFocus: true, noScroll: true });
  }

  /** chat-new started its session — rewrite the pane param in place (replaceState: no history spam). */
  function paneSessionCreated(id: string): void {
    void goto(withPaneParam(page.url, { kind: 'chat', sessionId: id }), {
      replaceState: true,
      keepFocus: true,
      noScroll: true
    });
  }
```

Wrap the main snippet's `MainColumn` in `PaneHost` (PaneHost OUTSIDE MainColumn — the primary snippet contains the `MainColumn wide` wrapper from Task 6; the pane side manages its own scroll):

```svelte
  {#snippet main()}
    <PaneHost
      {primaryDescriptor}
      pane={paneDescriptor}
      paneContext={{
        placement: 'pane',
        openFile: openFileAsPrimary,
        sessionCreated: paneSessionCreated,
        onArchived: closePane
      }}
      onClose={closePane}
      onPromote={promotePane}
    >
      {#snippet primary()}
        <MainColumn wide>
          <!-- Task 6's branches, unchanged -->
        </MainColumn>
      {/snippet}
    </PaneHost>
  {/snippet}
```

Add the picker to the ListPane action area:

```svelte
      {#snippet action()}
        <div class="flex items-center gap-1">
          <SessionPickerPopover {mountKey} onOpenSession={openSessionPane} onNewSession={openNewSessionPane} />
          <NewEntryButton onNew={openNew} />
        </div>
      {/snippet}
```

- [ ] **Step 3: `/knowledge` index integration**

Same pattern, smaller: `selectedMountKey` is the mount; add `SessionPickerPopover` beside the index's ListPane action (`NewEntryButton`), and wrap its main snippet in the same `PaneHost` (primary descriptor `null` — the index shows no single file; a chat pane next to the index is still valid). All handlers identical to Step 2 with `mountKey` → `selectedMountKey` (guard: only render the picker when `selectedMountKey` is non-null).

- [ ] **Step 4: Verify**

`bun run test`, `bun run check`, `bun run build`. Functional: on a file page, picker → recent session → chat pane opens right and streams; picker → "New session" → composer pane; sending creates the session, URL rewrites to `chat:<id>` (replaceState), first prompt fires; clicking a file chip inside the chat pane navigates the LEFT file view and keeps the pane; archive from the pane header closes the pane; promote goes to `/chat?session=…`; reload restores the split view.

- [ ] **Step 5: Full-repo verify + acceptance sweep**

- `cd backend && mix test` — green.
- `cd frontend && bun run test && bun run check && bun run build` — green.
- Manual acceptance list (from the spec): all four entry points (tool chips, header tree popover, session picker, promote buttons); reload restores split; resize persists; non-md viewers (txt/pdf/image) from tree clicks; conflict banner when the agent edits an open file; invalid `?pane=` garbage in the URL is silently ignored.

- [ ] **Step 6: Commit**

```bash
git add frontend/src
git commit -m "feat(knowledge): chat side panes + session picker (reverse combo)

Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>"
```

---

## Self-review notes (resolved during plan writing)

- Spec's backend change #2 (`icm_mount` on summaries) already exists — consumed, not re-implemented (see header).
- Spec's "session picker in the knowledge PageHeader" landed in the ListPane action area instead — the PageHeader doesn't exist in every knowledge route state (file/folder/index differ), the list pane header does. Same affordance, stabler placement.
- The `chat:new:<mountKey>` → `chat:<id>` rewrite uses `replaceState` so Back doesn't step through a dead composer state.
- paneforge/pdfjs API details are version-sensitive: both tasks direct the implementer to read the installed package's actual exports before finalizing those code blocks.
