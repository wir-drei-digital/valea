# Side Panes — Modular View Composition

**Date:** 2026-07-28
**Status:** Approved (design), pending implementation plan

## Goal

Let a file be viewed/edited next to a chat session — and, symmetrically, a chat
session next to a file — without leaving the current route. Build the pane
mechanism generically enough that future combos (e.g. mail next to chat) are one
registry entry plus an entry point, not a new layout.

Ships in this iteration, end to end:

1. **File next to chat** with two entry points: clicking a file location chip on
   a tool call card, and a file-tree popover behind the folder name in the chat
   session header.
2. **Chat next to file** (reverse combo) with one entry point: a session-picker
   popover in the knowledge page header (mount-scoped recent sessions + "New
   session").
3. Full editor in the file pane for `.md`; per-format viewers otherwise
   (pdf.js for PDFs, `<img>` for images, read-only monospace text as the
   default).

Explicitly **not** in scope: more than one side pane (no tiling manager), a
generic `/workspace` route, mail/calendar panes (architecture-ready only),
mobile layouts.

## Architecture

### View components

The two ~500-line route bodies are extracted into self-contained, props-driven
components that take identity as props instead of reading `page.url`:

- **`ChatView({ sessionId })`** — owns its `AgentSessionStore` lifecycle
  (create on prop change, dispose on unmount), transcript, composer, plan bar,
  and the new `SessionHeader`.
- **`FileView({ mountKey, path })`** — dispatches by format:
  - `.md` → existing `PageEditor` + `PageEditorStore` (full editing, debounced
    save, conflict banner)
  - `.pdf` → `PdfView` (lazy `import('pdfjs-dist')` so the bundle stays lean)
  - images → `ImageView` over the existing `/files/raw` endpoint
  - everything else → `PlainTextView`, read-only monospace over `/files/raw`

Routes become thin shells: `/chat` parses `?session=` and renders `ChatView` as
primary; `/knowledge/[...path]` parses the path and renders `FileView` as
primary. Existing URLs, sidebar nav, and MRU restore are untouched. The primary
view stays route-determined; only the side pane is registry-driven.

### View registry

`lib/panes/registry.ts` maps a view type (`file`, `chat`; later `mail`, …) to:

- the Svelte component to mount,
- a URL codec (`parse(string) → props | null`, `serialize(props) → string`),
- a `title(props)` function for the pane chrome.

### PaneHost and URL state

`lib/components/panes/PaneHost.svelte` replaces each route's direct main-area
rendering. It reads one **`?pane=`** query param via a pure
`lib/panes/pane-route.ts` helper:

- `?pane=file:<mountKey>/<relPath>` — e.g. `?pane=file:notes/projects/valea.md`
  (codec splits on the first `:`, then the first `/`; the remainder is the
  URL-encoded relative path)
- `?pane=chat:<sessionId>` — an existing session
- `?pane=chat:new:<mountKey>` — the new-session composer scoped to that ICM;
  when the session starts, the param is rewritten to `chat:<sessionId>`
  (mirroring how the chat route moves from `?icm=` to `?session=`)

No pane param → primary renders exactly as today. With a valid pane → a
paneforge `PaneGroup` (shadcn-svelte Resizable — the upgrade path already
designated in `AppShell.svelte` and `DESIGN_SYSTEM.md`) renders primary left,
side pane right, with a drag handle. Split ratio persists to
`localStorage['valea.pane-split']` and only updates on user drag.

The side pane has a slim chrome bar: registry title, an "open as full view"
button (promote: file pane → `/knowledge/<mount>/<path>`, chat pane →
`/chat?session=<id>`, replacing the current route), and a close button (drops
`?pane=`).

`pane-route.ts` rejects a side pane identical to the primary view (e.g.
`/chat?session=X&pane=chat:X`).

### AppShell changes

`AppShell`'s `mainVariant` prop (prose / prose-wide / column) is **absorbed into
the view components** — each view owns its own scroll container and width
behavior, which is what makes any view hostable in any pane. `AppShell`'s main
slot becomes a plain `flex-1 min-w-0` region; sidebar, list, and rail slots are
unchanged. The tiptap per-block 596px cap in `tiptap.css` becomes width-aware
(`min(596px, 100%)` relative to the pane, not the viewport) so the editor is
usable in a narrow pane.

## Components and refactors

### New

| Piece | Purpose |
|---|---|
| `lib/panes/registry.ts` | View type → component + codec + title (pure logic, tested) |
| `lib/panes/pane-route.ts` | Parse/serialize `?pane=`, reject invalid/duplicate (pure, tested) |
| `lib/components/panes/PaneHost.svelte` | Split rendering, paneforge group, pane chrome |
| `lib/components/agent/SessionHeader.svelte` | Extracted chat header; folder name triggers file-tree popover |
| `lib/components/ui/popover/` | shadcn wrapper over the bits-ui popover primitive (new install) |
| `lib/components/views/ChatView.svelte` | Extracted chat view |
| `lib/components/views/FileView.svelte` | Extracted file view + format dispatch |
| `lib/components/files/PlainTextView.svelte` | Read-only monospace viewer |
| `lib/components/files/PdfView.svelte` | pdf.js viewer (lazy-loaded) |
| `lib/components/files/ImageView.svelte` | Image viewer over raw endpoint |

New dependency: `paneforge` (via shadcn-svelte Resizable). `pdfjs-dist` added
as a lazy-loaded dependency.

### Refactors (behavior-preserving)

- `routes/chat/+page.svelte` and `routes/knowledge/[...path]/+page.svelte`
  shrink to thin shells (URL parsing + list panes + `PaneHost`).
- `IcmTree.svelte` gains an optional `onSelect(mountKey, path)` mode: rows call
  the handler instead of rendering `<a href>` navigation. Default `<a href>`
  behavior on `/knowledge` is unchanged.
- **Non-`.md` rows become clickable everywhere** (knowledge tree and popover
  tree) now that `FileView` can render them. The deliberate inert-row special
  case in `icmToNav` / tree rows is removed; non-`.md` selections on
  `/knowledge` route to the same `FileView` dispatch.

## Entry points

1. **Tool-card file chips** — `ToolCallCard` renders a chip per file location
   on the tool item (path + optional line). Click sets `?pane=file:…`. Chips
   render only for mount-relative locations (see backend).
2. **Session-header popover tree** — the folder name in `SessionHeader` opens a
   popover hosting the session's mount-scoped `IcmTree` in `onSelect` mode;
   selecting a file opens it in the side pane.
3. **Session picker on knowledge pages** — the knowledge `PageHeader` (index
   and file routes) gets a popover listing that mount's recent sessions
   (`recentSessionsStore.groups` filtered by mount key) plus a "New session"
   action. Picking a session opens `ChatView` in the side pane; "New session"
   opens the pane in the existing new-session composer state scoped to that
   ICM.
4. **Promote button** in pane chrome (described above).

## Backend changes

Two small changes:

1. **Relay tool locations.** In `backend/lib/valea/acp/connection.ex`,
   `reduce_update` for `tool_call` / `tool_call_update` merges ACP's
   `toolCall.locations` onto the tool item. Each location is relativized
   against the session's `icm_root` using the existing case-folded `Paths`
   helpers: emit `{path, line}` with the mount-relative path when the file is
   under the root. Locations outside the mount are relayed as absolute paths;
   the frontend renders clickable chips only for mount-relative ones. A
   matching `toolLocations` accessor goes into
   `frontend/src/lib/components/agent/item-shapes.ts`.
2. **`icm_mount` on session summaries.** `AgentSessionSummary` gains the mount
   key (already persisted in session meta; only `icmName` is exposed today).
   This closes the documented gap where `resolveActiveMountKey` returns `null`
   for sessions outside the recent-sessions cap, and it is what the header
   popover tree and pane restore key off.

## Data flow and lifecycles

- Each `ChatView` instance owns one `AgentSessionStore` → one
  `agent_session:<id>` channel; keyed `$effect` on the `sessionId` prop,
  disposed on unmount or prop change. Pane open/close/resize must **not**
  recreate the primary view's store: the current route `$effect` that tears
  down on any URL change is rewritten to react only to its own param.
- `workspace:events` keeps its single root-layout join. Views subscribe via the
  existing store-listener sets (`icmStore.onIcmChanged`, …). **No new channel
  joins from panes.**
- `FileView` constructs `PageEditorStore` per open `.md` file exactly as the
  knowledge route does today; non-md viewers fetch from the raw endpoint with
  no store.

## Error handling

- Invalid or unparseable `?pane=` → silently ignored; primary renders alone.
- File missing/deleted or mount degraded → `FileView` renders the existing
  `EmptyState` pattern inside the pane; pane stays closable.
- Chat pane session id that no longer exists → same in-pane empty state.
- Agent writes to a file the user has open in a pane → existing
  `ConflictBanner` machinery, unchanged.
- Pane minimum widths via paneforge `minSize` (~320px per side).
- pdf.js load failure → plain-text fallback message in the pane.

## Testing

Repo convention: pure logic extracted to sibling `.ts`, tested with Vitest; no
component render harness.

- `pane-route.test.ts` — parse/serialize round-trips, invalid input,
  duplicate-of-primary rejection, paths with slashes/unicode.
- `registry.test.ts` — codecs and titles per view type.
- `item-shapes.test.ts` — `toolLocations` accessor against raw item maps
  (with/without locations, relative vs. absolute paths).
- Backend ExUnit — `reduce_update` location merging + relativization edge cases
  (outside-root, case-folded), `icm_mount` on summaries.
- Manual acceptance — all four entry points, reload restores the split, resize
  persistence, promote/close, non-md and pdf viewers, agent-edit conflict
  banner in a pane.

## Decisions log

- **Approach:** registry + PaneHost inside existing routes (chosen over a
  generic `/workspace` tiling route and over per-route bolt-on).
- **File pane is a full editor**, not read-only.
- **Non-md handling:** plain text default, per-format viewers (pdf.js), chosen
  over md-only and over a full code editor (CodeMirror explicitly deferred).
- **Pane state in URL** (`?pane=`), split ratio in localStorage.
- **Backend relays tool locations** (chosen over frontend title parsing).
- **Reverse-combo entry point:** session picker popover in the knowledge
  header.
