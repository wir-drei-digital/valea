# Knowledge & Editor Depth — Links, Backlinks, Templates, Search, Images (ICM Spec C)

**Date:** 2026-07-12 · **Status:** approved design, pre-plan
**Depends on:** 2026-07-10-icm-editor-design.md (tiptap editor, deterministic
markdown round-trip, tree CRUD, version guard), 2026-07-12-icm-mounts-design.md
+ 2026-07-12-icm-by-reference-design.md (mount model, physical-path
vocabulary, grouped Knowledge tree, `Valea.ICM.References`). Companion to
2026-07-12-methodology-depth-design.md (Spec B) — C ships the starter-mount
`Templates/Decision.md` that pairs with B's `Decisions/` convention.

## Goal

Make the Knowledge section a genuinely pleasant place to live in daily:
pages link to each other with a picker, every page shows what references
it, new pages start from templates, everything is findable in one
keystroke, and images paste straight into pages — all without a single
byte of non-standard markdown on disk. Implements the editor spec's
deferred items: wikilinks/backlinks, page templates, search,
images/attachments.

## Architectural posture — the filesystem IS the index

No search index is built this phase. The workspace is small (a
solopreneur ICM is hundreds of pages, a few MB); after the first read
the OS page cache holds it, and a full scan lands in tens of
milliseconds. Search and backlinks are served by on-demand scans, and
the RPC seam is deliberately implementation-agnostic:

- `search(query, mount?)` and `backlinks(path)` are stable contracts.
  If a later phase brings mail search or multi-thousand-page mounts,
  SQLite FTS5 (the sanctioned index layer in `app.sqlite`) drops in
  behind the same RPCs without touching the UI. That upgrade path is
  named here so nobody re-litigates it.
- Scans cover **enabled** mounts only (embedded and external alike,
  physical-path vocabulary); degraded/disabled mounts are excluded,
  matching the tree and registry.
- Mounts are scanned concurrently; a mount that does not answer within
  500 ms (e.g. a cold network-synced external folder) is skipped for
  that query and the result carries a "search incomplete — <mount> is
  slow/unreachable" notice instead of blocking.

## 1. Search

**Backend (`Valea.ICM.Search`):** per query, walk enabled mounts' `.md`
files (knowledge pages and workflow contracts alike — they are all
mount content), case-insensitive match on every whitespace-separated
term (AND semantics; the final term also matches as a prefix, for
as-you-type), rank by heuristic weight — title (first `h1`, else
filename) > headings > body, scaled by occurrence count — and cut a
snippet around the first body match with match offsets for
highlighting. Top 20 results: `{path, mount, title, snippet,
highlights}`. Query text is treated as literal text throughout — there
is no query syntax to escape or injection surface to defend.

**Frontend:** a global **Cmd+K palette** — debounced (~150 ms)
as-you-type, results show title, mount badge, highlighted snippet;
Enter navigates to the page; an empty query lists the 10 most recently
opened pages (a frontend-held MRU). Mail/queue/sources are out of scope — they
have their own views.

## 2. Links in the editor

**On disk: standard GFM links only.** Destination `<…>`-wrapped when
the path contains spaces. Path rule:

- Source and target both inside the workspace (same mount, or embedded
  ↔ embedded): destination is the **relative path from the linking
  page** — renders as a working link in any tool, agent-followable
  bare.
- Either end in an external mount: destination is the **absolute
  physical path** — explicitly non-portable, per Spec A2's
  cross-boundary rule.

**Editor UX:** typing `[[` or `@` opens an inline page picker powered by
the same search RPC; selecting inserts a standard link whose text is
the target's title. Clicking a `.md` link navigates the Knowledge route
(external paths included — that plumbing exists); non-`.md` targets
render as inert file references. **Dangling links** render in a subtle
broken style; clicking one offers "Create this page" via the existing
create RPC. The vendored converter already round-trips GFM links; no
custom nodes.

## 3. Backlinks

**Backend (`Valea.ICM.Backlinks`):** the References trick, generalized.
For a target page: substring pre-filter across enabled mounts for the
target's filename (cheap), then AST-parse only the candidate pages and
confirm real link/image destinations that resolve (relative-from-source
or absolute) to the target. Returns `{source_path, mount, link_text}`
per inbound link. The RPC unions this with
`References.referencing_workflows/1`, so one call answers "what
references this page" — pages *and* workflows.

**Frontend:** the page view gains a "Referenced by" panel (grouped:
pages, workflows; click-through; quietly absent when empty). Rename and
delete dialogs extend their impact counts to both kinds: "Also updates
2 pages and 1 workflow."

## 4. Rename/move integrity — surgical, never re-serialized

Renaming a page or folder rewrites inbound in-content links by
**in-place replacement of the exact destination span** inside the link
syntax, using source positions from a fresh parse of each confirmed
referencing page. The referencing file is never round-tripped through
the converter — every byte outside the destination spans stays
identical, preserving the determinism contract. Relative destinations
are recomputed per source page; image destinations are rewritten the
same way. Pages inside external mounts are rewritten too (the editor
already holds human-edit authority there). Workflow `sources:`
rewriting stays in `References`, unchanged; both run under the same
rename operation and both are reflected in the impact dialog.

## 5. Templates

`Templates/` per mount — each template an ordinary page (searchable,
editable, visible in the tree). The new-page dialog gains a template
select listing the target mount's `Templates/*.md`. Instantiation is
server-side: copy the template bytes, substitute `{{title}}` (the new
page's name) and `{{date}}` (ISO `YYYY-MM-DD`), write the new page —
any other `{{…}}` text is left verbatim. The starter template mount
ships `Templates/Client.md` and `Templates/Decision.md` (the latter
pairing with Spec B's `Decisions/` convention), and the mount's
`AGENTS.md` documents the convention so an agent creating pages —
through Spec B proposals or a bare session — reads the same templates.
No mechanism beyond the convention.

## 6. Images & attachments

Paste or drag an image into the editor → upload → stored as
`Assets/<page-slug>-<hash8>.<ext>` at the **target mount's root** →
standard `![alt](<relative path>)` inserted. Transport is two small
HTTP endpoints on the sidecar (multipart `POST` upload, `GET` serve)
behind the editor's mount-rooted symlink-hardened containment — `GET`
strictly read-only and mount-contained, `POST` capped at 10 MB with an
image content-type allowlist. A non-image file dropped in becomes an
ordinary link instead of an image node. The editor renders image nodes
via the `GET` endpoint; on disk the page stays plain markdown with a
relative path any renderer resolves. Deleting a page leaves its assets
(user-owned files; nothing is silently deleted).

## Trust & product framing

Everything here deepens "your business runs on folders you own":
links are ordinary markdown any tool renders, templates are ordinary
pages, search reads your files directly (no shadow database this
phase), images are ordinary files beside your pages. "Open the hood"
keeps showing exactly what the app shows.

## Error handling

| Failure | Behavior |
| --- | --- |
| Slow/unreachable mount during a scan | Skipped for that query; result carries an honest "search incomplete" notice |
| Dangling link target | Broken-link style + "Create this page" |
| Link rewrite touches a page open in the editor | Page hash moves → existing reload banner; no data loss |
| Rename impact scan finds an unparseable page | Page listed as "could not check" in the dialog; rename proceeds without touching it |
| Template placeholder other than `{{title}}`/`{{date}}` | Left verbatim (documented in the template pages themselves) |
| Upload too large / not an allowed image type | Calm inline error; nothing written |
| Upload target mount disabled/degraded mid-flight | Rejected by containment; calm error |
| `[[` picker with zero results | Offers "Create page" inline (same affordance as dangling links) |

## Testing

- **Search:** term-AND + prefix semantics, title/heading/body
  weighting, snippet + highlight offsets, mount exclusion
  (disabled/degraded), concurrent-scan timeout path, literal-text
  queries containing regex/FTS metacharacters.
- **Backlinks:** pre-filter + AST-confirm matrix (true links, prose
  mentions that are not links, image refs, relative vs absolute
  destinations, external-mount sources), union with workflow
  references.
- **Rename integrity:** byte-precision (every byte outside destination
  spans identical), relative-path recomputation (same-mount, embedded ↔
  embedded, external absolute), folder renames, image destinations,
  unparseable-page skip.
- **Templates:** substitution is simple textual replacement —
  `{{title}}`/`{{date}}` are substituted even inside code fences
  (documented); unknown placeholders untouched; per-mount template
  listing.
- **Uploads:** containment escapes, size cap, type allowlist, slug/hash
  naming, GET read-only + containment.
- **Frontend:** palette/picker state machines and result rendering via
  the pure-extraction pattern; link insertion path rules; dangling-link
  affordance.
- **Acceptance:** see below.

## Acceptance scenario

Create a Client page from the template (title and date substituted) →
link it from a session-notes page via `[[` (standard markdown link on
disk, title as text) → the Client page's "Referenced by" shows the
session page → rename the Client page (the link is rewritten
byte-surgically; a concurrently open editor shows the reload banner;
the impact dialog counted pages and workflows) → Cmd+K finds the page
by body text with a highlighted snippet → paste a screenshot into it
(file lands in the mount's `Assets/`, renders in the editor, `cat`
shows a plain relative image path) → click a dangling link on another
page and create the target on the spot. All of it byte-inspectable in
the workspace folder.

## Non-goals this phase

Any persistent search index (FTS5 is the named upgrade path behind the
stable RPCs), version history, structured-facts blocks, tags, graph
view, saved searches, search over sources/queue/mail, OS-open of
non-md targets, orphan-asset cleanup, collaborative editing.
