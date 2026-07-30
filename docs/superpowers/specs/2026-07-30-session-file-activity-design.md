# Session File Activity — Rail of Files Read/Edited

**Date:** 2026-07-30
**Status:** Approved (design), pending implementation plan

## Goal

While viewing a chat session — live or reopened later — show which files the
session read and which it changed, with the change diffs available on demand.
The surface is a right-hand rail inside the chat view, designed to be
approachable for non-technical users: plain file names, one badge per row, and
all diff detail hidden until deliberately expanded.

Ships in this iteration, end to end:

1. **`FileActivityRail`** — a third column in `ChatView` (primary placement
   only), one row per file with a badge (`Read` / `Edited` / `Created` /
   `Deleted` / `Renamed`), expandable per-edit diffs, and an open-in-pane icon.
2. **Auto-open on first file touch**, per-session close memory, and a
   "Files · N" reopen toggle in `SessionHeader`.
3. **Pure-frontend aggregation** over the session store's existing tool items —
   no backend changes.

Explicitly **not** in scope: attribution of shell-level renames/deletes (`mv`/
`rm` inside Bash calls) to the session — a backend session file journal is the
future path; mobile layouts; any revert/undo affordance.

## Architecture

### Data source (already shipped)

`AgentSessionStore.items` holds the full session timeline — attach snapshot
plus live updates — so the rail works identically for running and reopened
sessions. Tool items already carry everything needed
(`item-shapes.ts` accessors, fed by `Valea.Acp.Connection`):

- `kind` — ACP tool kind, relayed verbatim (`read`, `edit`, and — when an
  adapter sends them — `delete`, `move`).
- `locations` — `[{path, relPath?, line?}]`, backend-relativized; `relPath`
  present only for files inside the session's mount.
- `diff` — `{path?, oldText?, newText?}` per edit call (region snippets, not
  whole files).
- `status` — `completed` / `failed` / running.

### Aggregation module

New pure module `frontend/src/lib/components/agent/file-activity.ts` with a
sibling Vitest file (repo convention: pure logic in `.ts`, no component
harness):

```
deriveFileActivity(items: AcpItemLike[]): FileActivity[]

FileActivity = {
  key: string          // relPath ?? path — same dedupe identity the chips use
  relPath?: string     // present ⇒ openable in the file pane
  path: string
  name: string         // basename, shown prominently
  dir: string          // parent directory, secondary text ('' at mount root)
  kindBadge: 'read' | 'edited' | 'created' | 'deleted' | 'renamed'
  read: boolean
  edited: boolean
  edits: ToolDiff[]    // chronological (item seq order)
  lastSeq: number      // most recent touch, for sorting
}
```

Rules:

- Only `tool` items with file-bearing kinds (`read`, `edit`, `delete`, `move`)
  and **status `completed`** count. Failed and still-running calls are
  excluded — a failed edit changed nothing, and the derivation is reactive, so
  a running edit appears the moment it completes.
- File identity comes from `locations` (`relPath ?? path`), deduped exactly as
  `ToolCallCard` dedupes chips. A diff whose own `path` disagrees with the
  location still files under the location — locations are the
  backend-relativized truth.
- **Badge precedence** (highest wins): `deleted` > `renamed` > `created` >
  `edited` > `read`. A file read then edited shows `Edited` — the edit implies
  it was examined.
- **`created` inference:** the file's first completed edit diff has absent or
  empty `oldText` and non-empty `newText`. Implementation must verify against
  the live adapter that overwrites of existing files DO carry `oldText`; if
  that does not hold, the inference is dropped and such files show `Edited` —
  never guess.
- `delete` / `move` kinds map to `Deleted` / `Renamed` badges. For `move`,
  the row shows the destination location's name with the origin as secondary
  text when both locations are present. These kinds essentially never arrive
  from the current Claude Code adapter (it shells out via Bash, kind
  `execute`) — the mapping is correctness-for-free for adapters that do send
  them.
- **No diff merging.** Multiple edits stack chronologically in the expanded
  row. `oldText`/`newText` are region snippets; merging them into one
  file-level diff would be invented data.
- Sort: changed files (any non-`read` badge) first, then most-recently-touched
  (`lastSeq` desc) within each group.

### Existence cross-check

Shell-level deletions can't be attributed from tool items, but reality is
checkable: the workspace already maintains a live file tree (`icmStore`).
Rows whose `relPath` no longer resolves in the current tree get a muted
"no longer exists" note. Deliberately **not** a `Deleted` badge — we know the
file is gone, we do not know this session removed it, so we don't claim it
did. The check is a pure helper over the tree the store already holds
(re-evaluated on the existing `onIcmChanged` signal); files without `relPath`
(outside the mount) are never checked.

## UI

### FileActivityRail

New `frontend/src/lib/components/agent/FileActivityRail.svelte`, rendered by
`ChatView` as a right-hand column (~300px, own scroll region, hairline left
border) beside the transcript, only when `context.placement === 'primary'` —
a chat mounted as a narrow side pane never shows the rail. Below ~860px of
view width (≈560px transcript minimum + the 300px rail) the rail hides so a
squeezed window degrades gracefully.

Rows:

- Basename prominent; parent dir as muted meta text. Both are agent-produced
  strings: plain interpolation only, `{@html}` forbidden (same rule as every
  agent component).
- One badge per row: `Edited`/`Created`/`Deleted`/`Renamed` in the accent
  tint, `Read` in a neutral tint. Rows with >1 edit add a small "N edits"
  meta note.
- Rows with a changed badge expand on click (chevron): each completed edit
  renders as a `DiffBlock` over `lineDiff(oldText ?? '', newText ?? '')`,
  stacked chronologically — or a quiet "no change details available" line for
  a call that carried no `diff` payload (so `edits` entries preserve the
  call's presence even when its diff is absent). **Collapsed by default —
  diffs stay hidden until a deliberate expand.** `Read` rows are not
  expandable.
- An open icon (↗) on rows with `relPath` calls `context.openFile({mountKey,
  path})`, with the `mountKey` supplied by `ChatView` (it already resolves the
  session's mount for its header) — the file opens in the existing
  `?pane=file:` side pane, so the list and the file are visible together.
  Rows without `relPath` render the full path as plain text, no icon (same
  rule as tool-card chips).

### Visibility lifecycle

- **Auto-open** when the derived file count transitions 0 → >0 — first touch
  in a live session, or attaching to a session that already has activity.
- The rail's ✕ close is remembered **per session id in an in-memory
  module-level map** — once closed, that session won't reopen the rail this
  app run (including on later touches). Deliberately not persisted: a fresh
  app launch starts from default behavior.
- When the rail is closed and the count is > 0, `SessionHeader` shows a
  "Files · N" toggle to reopen it. No activity ⇒ no toggle, no rail, zero
  footprint. The open/close decision lives in `ChatView` (it owns both header
  and rail); the auto-open predicate is a pure helper in `file-activity.ts`.

### Tone

No file-tree jargon and no +/- counts in the collapsed state — names, badges,
and plain-language notes only. Mono diff detail appears only after an expand.

## Error handling and edge cases

- Oversized diffs → `lineDiff`'s existing 400-row cap + `DiffBlock`'s
  "diff truncated" note; nothing new.
- Session with no file activity → rail never appears, header shows no toggle.
- Mount degraded / tree unavailable → existence check simply reports
  "exists" (no note); the rail itself never blocks on the tree.
- Renames/deletes performed via shell commands are not attributed (documented
  v1 limitation; surfaced only via the "no longer exists" note).

## Testing

- `file-activity.test.ts` (Vitest): dedupe across calls; read+edit badge
  precedence; `created` inference incl. the ambiguous-overwrite fallback;
  `delete`/`move` mapping; chronological edit ordering; failed/running
  exclusion; outside-mount rows; sort order; auto-open predicate transitions;
  existence-check helper (present, missing, no-relPath, empty tree).
- Backend: no changes, no tests.
- Manual acceptance: live touch auto-opens the rail; close stays closed for
  that session; "Files · N" reopens; expand shows stacked diffs; ↗ opens the
  file side pane next to the rail; reopened past session shows its record;
  chat-as-side-pane never shows the rail; narrow window hides it.

## Decisions log

- **Placement:** rail inside `ChatView` (chosen over a `?pane=files:` registry
  type — fights the single-pane slot — and over a header popover — can't be
  ambient, cramped for diffs).
- **Organization:** one row per file with badges (chosen over a chronological
  audit log and over Changed/Read sections).
- **Visibility:** auto-open on first file touch, per-session close memory,
  header reopen toggle.
- **Row click expands; open is a separate icon** (diff-first, per
  "hidden by default").
- **Past sessions get identical behavior** — the attach snapshot makes it
  free.
- **Deletions/additions/renames:** three-layer answer — free ACP
  `delete`/`move` kind mapping, `created` inference from empty `oldText`
  (with verified fallback), and the live-tree "no longer exists" cross-check.
  Full shell-level attribution deferred to a future backend session file
  journal.
