# ICM Editor — Design (Phase 2)

**Date:** 2026-07-10
**Status:** Draft — pending user review
**Scope:** Sub-project 2 — brief Phase 2 (ICM viewer/editor), expanded per product
decisions below.

## Context

Phase 1 shipped the foundation: workspace lifecycle, ICM tree reads behind a
containment chokepoint, live nav via the file watcher, and a read-only raw
`<pre>` page view. This phase makes the ICM editable — the human half of the
teach-your-assistant loop.

ICM is now formally grounded: *"Interpretable Context Methodology: Folder
Structure as Agent Architecture"* (Van Clief & McDermott,
arxiv.org/html/2603.16021v2) names and validates the approach. The mapping:
Valea's `icm/` is the paper's **Layer 3** (stable reference material, the
"factory config", 500–2k tokens per page); `workflows/*.yaml` with their
`sources:` lists are **Layer 2 stage contracts with inputs tables**; `queue/`
and `sources/` are **Layer 4 working artifacts** behind review gates. Three
design consequences of the paper appear below: deterministic serialization as
a contract (§Save loop), reference-aware rename/delete (§Tree CRUD), and the
per-page context-cost indicator (§Page view).

Product decisions made in brainstorming:
- **Notion-like WYSIWYG** via tiptap (magus-proven pattern), markdown stays
  the on-disk truth, raw view one toggle away.
- **Full tree CRUD**: create page/folder, rename, delete.
- **Version guard + reload banner** for conflicts (optimistic concurrency
  adapted to files; external edits are first-class, not an error).
- **No dependency on tiptap_phoenix**: its LiveView core is unusable in the
  SPA; the three framework-agnostic extensions + CSS are vendored (hand-copied
  with origin headers).
- **Server-side markdown ↔ ProseMirror conversion** (approach A): vendor
  magus's pure-Elixir converter. Rejected: extracting a shared hex package now
  (premature coupling of two products), and browser-side conversion via
  tiptap-markdown (non-deterministic round-trip, forfeits backend-as-single-
  writer, which Phase 3's audit/agent writes require).
- **Roadmap reorder** (recorded in VISION.md): the agent-prototype slice
  (minimal workflow execution + harness seam + queue/audit essentials, on the
  seeded mock email) moves up to Phase 3, so an end-to-end demo exists before
  mail/calendar. The paper's Layer 0/1 files (workspace `CLAUDE.md` /
  `CONTEXT.md`) are designed in that phase, not this one.

## Architecture

Markdown files remain the single source of truth. The editor never sees
markdown — it works in ProseMirror JSON, converted at the backend boundary:

```
disk .md ── MDEx parse ──► ProseMirror JSON ──► tiptap (Svelte 5, Notion-like)
   ▲                                                  │ onChange, 1s debounce
   └── deterministic to_markdown ◄── save RPC (JSON + base hash) ◄──┘
```

### Backend

- **`Valea.Markdown.ProseMirror`** — vendored from
  `magus/lib/magus/markdown/prose_mirror.ex` (+ `Profile` behaviour), with a
  minimal `Valea.Markdown.Profile` (standard CommonMark + GFM: headings,
  paragraphs, lists, task lists, tables, code blocks, links, emphasis,
  blockquotes; **no custom nodes** — the paper's "plain text as interface"
  principle: exotic structures would break agent legibility). Dependency:
  `mdex`. Pure, IO-free, unit-tested in isolation.
- **`Valea.ICM` write operations** — `save_page(path, pm_json, base_hash)`,
  `create_page(path)`, `create_folder(path)`, `rename(path, new_name)`,
  `delete(path)`. All paths pass the existing containment chokepoint. Writes
  are atomic (tmp + rename in the same directory). `save_page` converts
  JSON → markdown and refuses to write if the file's current content hash ≠
  `base_hash` (`{:error, :page_changed}`).
- **Versioning**: `icm_page` (existing read) gains a `hash` field — SHA-256 of
  the file bytes at read time. No mtime (unreliable across tools), no lock
  files.
- **Name validation** (single chokepoint beside containment): reject empty,
  `/`, `\`, leading `.`, names not ending `.md` for pages (append if absent);
  normalized NFC.

### RPC surface (on the existing `Valea.Api.ICM` resource)

- `icm_page` (changed): returns `{path, title, uri, hash, content,
  prosemirror}` — content stays for the raw view, `prosemirror` is the
  converted JSON.
- New actions: `save_icm_page(path, prosemirror, base_hash)` →
  `{hash, saved_at}`; `create_icm_page(parent_path, name)` → `{path}`;
  `create_icm_folder(parent_path, name)` → `{path}`;
  `rename_icm_entry(path, new_name)` → `{path, updated_workflows}`;
  `delete_icm_entry(path)` → `{deleted: true}`;
  `icm_entry_references(path)` → `{workflows: [{file, name}]}`.
- **All new actions use constrained map returns** (typed fields, not
  unconstrained `:map`) so the generated TS client is actually typed — this
  begins retiring the Phase-1 `Record<string, any>` caveat with the new
  surface instead of extending it. (Retro-typing the Phase-1 actions is not
  in scope.)
- Errors: `page_changed`, `not_found`, `name_invalid`, `already_exists`,
  `outside_workspace`, `workspace_not_open` — mapped to calm human copy in
  the frontend, `role="alert"`.

### Reference-aware rename/delete (paper-driven)

Workflow YAMLs reference pages by exact path in their `sources:` inputs
tables — pages are load-bearing. `Valea.ICM.References` scans
`{workspace}/workflows/*.yaml` (plain string scan for the workspace-relative
path, no YAML semantics needed) and:
- `rename` updates every referencing workflow file in the same operation
  (atomic per file) and returns which ones (`updated_workflows`).
- `delete` does NOT touch workflows; `icm_entry_references` lets the UI warn
  first ("New Inquiry Triage reads this page — it will fail to find it.").
- Folder renames update references to every page under the folder.

## Frontend

### Editor component

`frontend/src/lib/components/editor/PageEditor.svelte`, following the proven
magus Svelte-5 pattern (editor built in `$effect` + `untrack`, exported
imperative methods `getJSON/setContent/focus`, destroyed in cleanup +
`onDestroy`). Props: `{ content: pm-json, onChange, onFlush }`.

Extensions: StarterKit, Placeholder ("Write it the way you'd tell a new
assistant…"), Link, Typography, TaskList/TaskItem, Table family — plus the
three vendored tiptap_phoenix extensions (`slash_command.js`,
`bubble_menu.js`, `drag_handle.js`; copied into
`frontend/src/lib/editor/vendor/` with origin headers) and its `tiptap.css`
with every `--ttp-*` variable mapped onto Paper & ink tokens. Editor body
type is Instrument Sans per the design system §3 (Newsreader remains chrome:
page titles, not content). Skipped deliberately: wikilinks, tags, custom
blocks, images/uploads (no asset story in a plain folder yet).

### Page view (`/knowledge/[...path]`, page case)

Header row: mono breadcrumb `icm/<path>` · **Friendly view | Raw** segmented
pill (design system §10 progressive disclosure — friendly default, raw one
toggle away) · quiet meta line: save status ("Saved · 14:02" / "Saving…" /
amber "Unsaved") + **context-cost estimate** ("~640 tokens", chars÷4,
ink-meta — the paper's Layer-3 token budgets make page size a first-class
ICM property). Below: title, then tiptap (friendly) or read-only
`<pre>` markdown (raw). The ownership card stays.

### Save loop & conflicts

onChange → 1s debounce → `save_icm_page(path, json, base_hash)` → adopt
returned hash. Flush pending saves on route leave and on raw-view toggle
(save-on-blur semantics; no unsaved-changes modal). Conflict handling:
- Save rejected `page_changed` → amber suggestion-style banner: "This page
  changed outside the editor." **[Reload] [Keep mine]** (Keep mine = refetch
  hash only, resave own JSON on top — magus's LWW recovery).
- Watcher `icm_changed` while the page is **clean** → silent refetch + reload
  (external tools are first-class writers).
- While **dirty** → check via refetch whether this page's hash moved; if so
  show the banner pre-emptively.

### Tree CRUD UI

- "New page" / "New folder" affordances at the bottom of the Knowledge list
  pane and in folder views (quiet, secondary-outline).
- Row-level overflow menu (list pane + tree): Rename, Delete.
- Rename dialog shows reference impact before confirm: "Also updates 1
  workflow that reads this page." Delete dialog lists referencing workflows
  as a warning and states the consequence plainly: "This removes the file
  from your workspace folder."
- New pages seed with `# <Name>\n` (title convention). Creation navigates to
  the new page with the editor focused.
- Nav/list updates arrive via the existing watcher → `icm_changed` pipeline
  (no optimistic tree surgery).

## Determinism contract (paper-driven, load-bearing)

Opening and saving an untouched page MUST produce a byte-identical file. The
paper's update discipline ("changes to any input file signal that dependent
stages may need re-execution") and the user-owned git workspace both depend
on it: formatting churn would make every save look semantic. Enforced by a
test that round-trips **every seed page** (`markdown → PM JSON → markdown`,
assert equality) and a save-without-edit integration test. Where MDEx's
parse → our serializer can't reproduce an input byte-exactly (e.g. `*` vs
`-` bullets), the serializer's canonical form is applied ON FIRST REAL EDIT
only — the no-edit path must still never write (dirty tracking prevents
save calls when the editor document is unchanged).

## Error handling

Backend errors as listed under RPC; frontend maps to calm sentences (no
exclamation marks), `role="alert"`, consistent with the onboarding pattern.
Watcher/channel loss degrades exactly as Phase 1 (manual refresh; save still
guarded by hash). A failed save keeps the editor dirty and retries on next
change or manual save action (no data loss without a banner).

## Testing

- **Converter**: unit round-trip on every seed page (the strongest fixture
  set), GFM feature matrix (tables, task lists, code fences, links), profile
  isolation tests. Property-ish: `to_markdown(from_markdown(x))` idempotent
  on second pass for arbitrary seed-derived mutations.
- **Write ops**: version-guard rejection, atomic write behavior, containment
  escapes, name validation, rename reference-updates (fixture workspace with
  the four seed workflows), delete references listing, folder rename.
- **Frontend**: vitest for the save-loop state machine (debounce, flush,
  conflict, keep-mine) with a fake api; nav/CRUD store logic.
- **Acceptance**: (1) edit Founder Coaching Package in tiptap → file on disk
  shows a clean, minimal markdown diff; (2) open a page, don't edit, navigate
  away → zero diff; (3) edit the file in another editor while open → banner;
  Reload shows the external content; (4) create → rename (workflow reference
  updated, verified in the YAML) → delete (warning shown) round-trip, nav
  updating live; (5) raw view matches disk content exactly; (6) slash
  command, bubble menu, task list all function; (7) `just test` green.

## Out of scope (later phases)

Wikilinks/backlinks between pages, images/attachments, structured-facts
blocks (design system §8 — needs the memory-update suggestion flow),
memory-update suggestion cards, page templates, search, version history/undo
beyond the editor session (the workspace is git-friendly; in-app history is a
later feature), collaborative editing, retro-typing Phase-1 RPC actions.
