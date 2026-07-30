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
   "Context · N" reopen toggle in `SessionHeader`.
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
- `diff` — `{path?, oldText?, newText?}` (region snippets, not whole files).
  **At most one diff per tool call:** the relay keeps a single `diff` on the
  item (`put_tool_content/2` takes the first diff entry of an update; a later
  diff-carrying update overwrites it), and the timeline upserts items by id —
  so each call contributes its final reported diff, and a call reporting
  multiple regions loses all but one. Accepted v1 fidelity; multiple *calls*
  to one file still stack.
- `status` — `completed` / `failed` / running.

One store-shape caveat drives the ordering rule below: **snapshot items carry
no per-item `seq`** (only live pushes do — see the store's class doc), so
chronology must come from the item's index in the store's ordered `items`
array (stable-sorted, snapshot order preserved), never from `seq`.

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
  edits: FileEdit[]    // chronological (timeline-index order); one entry per
                       // completed edit call, diff optional (see attribution)
  lastIndex: number    // timeline index of the most recent touch, for sorting
}

FileEdit = { diff?: ToolDiff }   // entry preserved even when the call
                                 // carried no diff payload
```

Rules:

- Only `tool` items with file-bearing kinds (`read`, `edit`, `delete`, `move`)
  and **status `completed`** count. Failed and still-running calls are
  excluded — a failed edit changed nothing, and the derivation is reactive, so
  a running edit appears the moment it completes.
- File identity comes from `locations` (`relPath ?? path`), deduped exactly as
  `ToolCallCard` dedupes chips. `relPath` is the backend-*proven* in-mount
  identity; `path` is the agent's verbatim string (on Windows adapters it may
  use backslashes — see name derivation below).
- **Diff attribution is deterministic.** A call's diff attaches to exactly one
  row: the single location when there is one; with multiple locations, the
  location whose `path`/`relPath` equals or suffix-matches `diff.path`, else
  the first location; with no locations but a `diff.path`, a row synthesized
  from `diff.path` (plain text, not openable — the frontend never relativizes
  paths itself). Every other location of a multi-location edit call still gets
  a row (badge, no diff).
- **Badge precedence** (highest wins): `deleted` > `renamed` > `created` >
  `edited` > `read`. A file read then edited shows `Edited` — the edit implies
  it was examined.
- **`created` inference:** the file's first completed edit diff has absent or
  empty `oldText` and non-empty `newText`. Implementation must verify against
  the live adapter that overwrites of existing files DO carry `oldText`
  (nothing in the codebase establishes this — the relay passes absent fields
  through untouched); if it does not hold, the inference is dropped wholesale
  and such files show `Edited` — never guess. Known accepted miss even when
  enabled: creating an *empty* file (no `newText`) shows `Edited`.
- `delete` / `move` kinds map to `Deleted` / `Renamed` badges. Relayed
  locations carry **no origin/destination roles**, so a `Renamed` row claims
  no direction: it lists the call's location paths as row text, nothing more.
  These kinds essentially never arrive from the current Claude Code adapter
  (it shells out via Bash, kind `execute`) — the mapping is
  correctness-for-free for adapters that do send them.
- **No diff merging.** Multiple edits stack chronologically in the expanded
  row. `oldText`/`newText` are region snippets; merging them into one
  file-level diff would be invented data.
- Sort: changed files (any non-`read` badge) first, then most-recently-touched
  (`lastIndex` desc) within each group.
- Directory locations: no node-type data exists on locations, and the filtered
  kinds (`read`/`edit`/`delete`/`move`) make directories unlikely — rows
  render what locations claim, no special casing.

### Existence cross-check

Shell-level deletions can't be attributed from tool items, but reality is
checkable. **Not** via a pure traversal of `icmStore`'s tree — the tree is
deliberately lazy (root plus previously listed directories), so an unloaded
descendant is absent without being deleted and a traversal would fabricate
"missing". The check MUST go through `icmStore.ensurePathLoaded(mountKey,
path)`, whose contract exists for exactly this (issue #2): only a definitive
`'missing'` (every ancestor listing succeeded, node genuinely absent) renders
the muted "no longer exists" note; `'unavailable'` (any listing failed)
renders nothing; `'found'` clears the note.

Scope and timing: checked only for rows with a changed badge and a `relPath`,
only while the rail is open, re-run whenever `icmStore.groups` is
**reassigned** — which is how every `icm_changed` refetch lands.
Deliberately **not** the `onIcmChanged` listener: that callback fires before
its refetch settles, so a listener-driven recheck would walk the stale tree
through `loadDir`'s loaded-dir cache and miss a deletion permanently
(established during the plan's Codex review). Grafts from
`ensurePathLoaded`'s own lazy loads mutate nodes without reassigning the
array, so the dependency cannot loop. Pending async results are dropped by a
run token whenever the check re-runs or stops applying (rail closed, mount
changed). Deliberately **not** a `Deleted` badge — we know the file is gone,
we do not know this session removed it, so we don't claim it did.

## UI

### FileActivityRail

New `frontend/src/lib/components/agent/FileActivityRail.svelte`, rendered by
`ChatView` as a right-hand column (~300px, own scroll region, hairline left
border) beside the transcript, only when `context.placement === 'primary'` —
a chat mounted as a narrow side pane never shows the rail. Below ~860px of
**ChatView container width** (≈560px transcript minimum + the 300px rail) the
rail hides so a squeezed layout degrades gracefully. Container width, not
viewport, is the measurement on purpose: PaneHost's split gives each pane a
30% minimum, so opening a file from the rail can squeeze the primary chat
below the threshold — the rail then yields to the file pane, and reappears
when the pane closes. That hand-off is the accepted behavior on narrow
windows.

Rows:

- Basename prominent; parent dir as muted meta text. Derivation splits on `/`
  for `relPath` (backend-normalized) but on **both `/` and `\`** for verbatim
  `path` fallbacks — outside-mount paths from a Windows agent keep their
  original backslash form. No separator ⇒ the whole string is the name. Both
  are agent-produced strings: plain interpolation only, `{@html}` forbidden
  (same rule as every agent component).
- One badge per row: `Edited`/`Created`/`Deleted`/`Renamed` in the accent
  tint, `Read` in a neutral tint. Rows with >1 edit add a small "N edits"
  meta note.
- Rows with at least one `edits` entry expand on click (chevron): each
  completed edit renders as a `DiffBlock` over
  `lineDiff(oldText ?? '', newText ?? '')`, stacked chronologically — or a
  quiet "no change details available" line for a call that carried no `diff`
  payload (`edits` entries preserve the call's presence even when its diff is
  absent). **Collapsed by default — diffs stay hidden until a deliberate
  expand.** `Read` rows and edit-less `Deleted`/`Renamed` rows are not
  expandable (nothing hidden to show).
- An open icon (↗) on rows with `relPath` calls `context.openFile({mountKey,
  path})`, with the `mountKey` supplied by `ChatView` (it already resolves the
  session's mount for its header) — the file opens in the existing
  `?pane=file:` side pane, so the list and the file are visible together.
  Rows without `relPath` render the full path as plain text, no icon (same
  rule as tool-card chips).

### Visibility lifecycle

- **Auto-open** when the derived file count transitions 0 → >0. The initial
  attach **is** such a transition by definition: the store starts empty and
  the snapshot merge takes the derived count from 0 to N, so a reopened
  session with activity auto-opens without any special casing — the predicate
  is over the derived value, not over live events.
- The rail's ✕ close is remembered **per session id in an in-memory
  module-level map**, capped (~50 entries, oldest evicted) so an arbitrarily
  long app run can't grow it unboundedly — once closed, that session won't
  reopen the rail this app run (including on later touches). Deliberately not
  persisted: a fresh app launch starts from default behavior.
- When the rail is closed and the count is > 0 — and only where the rail
  could actually show (primary placement, ≥860px view width) — `SessionHeader`
  shows a "Context · N" toggle to reopen it. A chat side pane or a squeezed
  primary shows no pill: an affordance whose target cannot appear would be a
  dead end. No activity ⇒ no toggle, no rail, zero footprint. The open/close
  decision lives in `ChatView` (it owns both header and rail); the auto-open
  predicate is a pure helper in `file-activity.ts`.

### Accessibility

Rows follow `ToolCallCard`'s precedent: the expand toggle and the open icon
are **separate sibling buttons** (never nested interactive controls — the row
container is a plain div). The toggle carries `aria-expanded`, and takes its
accessible name from its visible text children (name, dir, meta, badge) — no
`aria-label`, deliberately: a label would MASK that text for screen readers,
dropping the badge and the "no longer exists" note. The open icon, having no
text, gets its own label ("Open <name>"). Badges are text, never color-only.
Focus order: toggle, then open icon, row by row.

### Tone

No file-tree jargon and no +/- counts in the collapsed state — names, badges,
and plain-language notes only. Mono diff detail appears only after an expand.

## Error handling and edge cases

- Oversized diffs → `lineDiff`'s existing 400-row cap + `DiffBlock`'s
  "diff truncated" note; nothing new.
- Session with no file activity → rail never appears, header shows no toggle.
- Mount degraded / listings failing → `ensurePathLoaded` answers
  `'unavailable'` → no note is rendered (never a false "no longer exists");
  the rail itself never blocks on the tree.
- Renames/deletes performed via shell commands are not attributed (documented
  v1 limitation; surfaced only via the "no longer exists" note).
- Paths the ICM tree never lists — dot-prefixed segments and the root
  `icm.yaml` (`Valea.ICM.shallow_entries/3`) — are skipped entirely:
  `ensurePathLoaded` answers a definitive `'missing'` for them even when they
  exist, so unlistable means unknowable, not gone.
- The check is CACHE-bound in the creation direction: a just-created file is
  absent from the loaded tree until the debounced `icm_changed` refetch
  (~200ms) reassigns `icmStore.groups`. `ChatView` absorbs that with a settle
  delay before checking, so the watcher-on path never flashes a false note.
  Residual limitation: when ICM file watching is DISABLED (`Valea.ICM.Watcher`
  — FS backend unavailable at open; the workspace still opens, "tree refreshes
  on navigation only") no push ever arrives, so a created file's row can claim
  "no longer exists" until a manual tree refresh. Deletions can never go wrong
  that way — with no refetch the row simply shows no note.

## Testing

- `file-activity.test.ts` (Vitest): dedupe across calls; read+edit badge
  precedence; `created` inference incl. the ambiguous-overwrite fallback and
  the empty-file miss; `delete`/`move` mapping (no direction claims);
  diff-attribution rule (single location, multi-location with/without
  `diff.path` match, diff-only synthesis); timeline-index ordering with
  seq-less snapshot items; failed/running exclusion; outside-mount rows incl.
  backslash-path name derivation; sort order; auto-open predicate incl.
  attach-as-transition; existence-note mapping over `EnsurePathResult`
  (`found`/`missing`/`unavailable` — only `missing` notes) plus every skip:
  reads, outside-mount rows, `deleted` badges, and unlistable paths
  (dot-prefixed segment, root `icm.yaml` — a NESTED `icm.yaml` is still
  checked).
- Backend: no changes, no tests.
- Manual acceptance: live touch auto-opens the rail; close stays closed for
  that session; "Context · N" reopens; expand shows stacked diffs; ↗ opens the
  file side pane next to the rail; reopened past session shows its record;
  chat-as-side-pane never shows the rail (nor the header pill); narrow window
  hides both.

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
- **Renamed "Files" → "Context" (2026-07-30 UI pass):** the rail header, the
  reopen pill, and the panel labels all say "Context · N" — the point of the
  surface is that these files are part of the session's context, and the old
  label undersold that. Internal identifiers (`filesCount`, `FileActivity`,
  ids) deliberately keep the files vocabulary — they describe the data, not
  the label.
- **Full-width chat container (2026-07-30 UI pass):** the session header and
  its border span the whole chat area and the transcript scrollbar sits at
  the pane's right edge, while the message stream and composer stay centered
  at 660px in their own wrappers; the rail header's vertical band matches the
  chat header's, so the two border-b lines read as one continuous rule.
- **Codex review folded in (2026-07-30):** timeline-index ordering replaces
  `seq` (snapshot items carry none); one-diff-per-call fidelity stated;
  deterministic diff↔row attribution; `move` direction claims dropped;
  existence check mandated through `ensurePathLoaded` (lazy tree makes
  traversal wrong; only `'missing'` may claim absence); container-width rail
  gating vs. PaneHost's 30% minimums; backslash-aware name derivation;
  attach-as-transition auto-open; close-map cap; a11y rules per
  `ToolCallCard` precedent.
