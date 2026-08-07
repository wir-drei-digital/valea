# File Tree, Code Viewing & Composer Pass — Design

**Date:** 2026-08-07
**Status:** Draft (design), pending user approval and implementation plan

## Goal

Six independent improvements, grouped because four of them land in the file
tree and two in the chat dock. Each ships on its own and none depends on
another.

1. **Syntax highlighting** for code files in the file viewer, and for fenced
   code blocks in the chat transcript.
2. **File endings shown for every leaf** in the tree — today a `.md` page
   renders as `notes`, and only the filesystem knows it is `notes.md`.
3. **A file-type icon before the name**, replacing the uppercase format badge
   that trails it; folders swap their chevron for an open/closed folder glyph.
4. **A right-click context menu** on tree rows — reveal in the OS file
   manager, rename, delete, and the actions that today are only reachable
   through hover buttons or the `⋯` overflow.
5. **The composer's working indicator stops getting stuck**, and it names the
   work that is actually running instead of saying "Working…" for everything.
6. **Composer option chips are remembered**, so a model chosen once is the
   model the next session starts with.

Explicitly **not** in scope: highlighting inside the TipTap page editor's code
blocks (a `CodeBlockLowlight` extension — a larger, separate piece of work) or
inside `DiffBlock`; a Duplicate/copy action (considered, costed, and dropped —
see §4); anything about the tree's lazy-loading or persistence behaviour.

---

## 1. Syntax highlighting

### The engine, and why not a plain HTML string

`highlight.js` is the right engine — mature, ~200 grammars, class-based output
that can be themed with our own tokens rather than a vendored colour scheme.
Its normal API returns an **HTML string**, which would have to reach the DOM
through `{@html}`. Every component under `agent/` carries an explicit
`{@html}` FORBIDDEN note, and the file viewer renders user-authored bytes, so
introducing the project's first `{@html}` for a convenience is the wrong trade
even though highlight.js escapes its own input.

So: **`lowlight`** (v3) — the same highlight.js engine, wrapped to return a
**hast tree** (plain data: `{type, tagName, properties.className, children}`)
instead of a string. A small recursive Svelte component renders that tree into
real elements. No HTML string ever exists, `{@html}` stays unused, and the
class names are still `hljs-keyword`/`hljs-string`/… so theming is pure CSS.

`lowlight` is also what TipTap's `CodeBlockLowlight` uses, so if editor
highlighting is ever picked up it shares this dependency rather than adding a
second engine.

**New dependencies:** `lowlight@^3` (pulls `highlight.js@^11`).

### Modules

- **`lib/highlight/languages.ts`** — pure, tested. Two exports:
  - `grammarForExtension(ext: string): string | null` — `.ex`/`.exs` →
    `elixir`, `.ts`/`.mts`/`.cts` → `typescript`, `.rs` → `rust`, and so on
    across roughly thirty extensions (source, config, data, shell, SQL,
    Dockerfile, Makefile, diff). Extension-less well-known basenames
    (`Dockerfile`, `Makefile`, `Justfile`) are matched on the whole basename.
  - `grammarForFence(info: string): string | null` — the ` ```ts ` info
    string, lowercased, first word only, through the same alias table.

  Both return `null` for anything unmapped, which means "render plain" — never
  a guess. `.svelte` and `.vue` map to `xml`: a deliberate approximation that
  gets tags and attributes right and expression interpolation wrong, recorded
  here so nobody later reads it as a bug.

- **`lib/highlight/registry.ts`** — grammar loading. A `Record<string, () =>
  Promise<LanguageFn>>` of **literal** dynamic imports
  (`() => import('highlight.js/lib/languages/elixir')`), so Vite can split one
  chunk per grammar; a template-literal specifier would defeat that. A
  module-level `Map<string, Promise<void>>` makes each grammar load exactly
  once per app lifetime, and registration into a shared `createLowlight()`
  instance is idempotent.

- **`lib/highlight/CodeBlock.svelte`** — the one rendering surface.
  Props: `{ code: string, grammar: string | null, class?: string }`.
  It renders the plain text immediately, then swaps in the highlighted tree
  once the grammar resolves. Same `<pre>`, same typography, same padding in
  both states, so the upgrade causes no layout shift and no flash.

- **`lib/highlight/HastNode.svelte`** — recursive renderer: a `text` node
  becomes an interpolated string, an `element` becomes
  `<span class={properties.className}>` around its children. It handles the
  only two node types lowlight emits and ignores anything else.

### Guards

- **Size.** Highlighting is skipped above `MAX_HIGHLIGHT_BYTES = 200_000`, and
  skipped outright when `capped-text.ts` reports the read was `truncated` —
  the viewer already caps display at 500 KB, and tokenising a half-megabyte
  file blocks the main thread for long enough to feel like a hang. Over the
  cap the block renders exactly as it does today.
- **Failure.** A grammar that fails to load, or a `lowlight.highlight` that
  throws, leaves the plain text in place. Highlighting is an enhancement,
  never a dependency — the same posture `persist.ts` takes toward storage.

### Theme

`.hljs-*` classes are mapped to **new design tokens** in
`frontend/src/routes/layout.css`, defined for both themes:

`--color-code-keyword`, `--color-code-string`, `--color-code-comment`,
`--color-code-number`, `--color-code-fn`, `--color-code-type`,
`--color-code-attr`, `--color-code-punct`.

Each highlight.js scope is folded onto one of those eight (e.g. `hljs-title`,
`hljs-title.function_` → `-fn`; `hljs-built_in`, `hljs-type` → `-type`), so the
palette stays small enough to reason about and to contrast-test. Unmapped
scopes inherit body ink rather than falling back to a vendor colour.

A case joins `lib/design/contrast.test.ts` pinning every code token at AA
against `--color-paper-track` (the code block's background) in **both**
themes — the same treatment the redesign gave warn-on-tint.

### Call sites

- **[`PlainTextView.svelte`](../../../frontend/src/lib/components/files/PlainTextView.svelte)**
  — the fallback viewer for every format without a dedicated one. It already
  holds `path`, so the grammar comes from `grammarForExtension`.
- **[`MarkdownBlocks.svelte`](../../../frontend/src/lib/components/agent/markdown/MarkdownBlocks.svelte)**
  — the `token.type === 'code'` branch, grammar from `token.lang` through
  `grammarForFence`. The existing `unescapeMarked` step is unchanged; it feeds
  `CodeBlock`'s `code` prop instead of a `<pre>` body.

---

## 2. File endings for every leaf

`Valea.ICM`'s tree sends a page's `name` as `Path.basename(abs, ".md")` and a
file's as the full basename. So `.md` is the one extension the tree hides, and
it hides it on the most common file in an ICM.

**Change:** one line in [`icmToNav`](../../../frontend/src/lib/shell/nav.ts) —
the page branch builds `label: n.name + '.md'`. The backend is untouched:
`name` stays the stripped basename for every other consumer, and only the tree
label gains the extension.

`label` is also what `EntryMenu` hands to `RenameDialog` as the prefill and to
`chatNewHref` as the origin label. Both are fine and both improve:

- Rename now pre-fills `notes.md` instead of `notes`. The backend's
  `ensure_md_extension/1` returns a name already ending in `.md` unchanged, so
  a submitted `notes.md` renames to `notes.md` — no double extension, no
  behaviour change beyond the user seeing the real filename.
- A session's origin label reads `notes.md`, which is what the user sees in
  the tree.

`nav.test.ts` and any label assertions elsewhere are updated.

---

## 3. Icons before the name

### What goes

The trailing badge at
[`IcmTree.svelte:285`](../../../frontend/src/lib/components/shell/IcmTree.svelte)
and its twin on the anchor form, plus `fileLeafLabel` in `file-leaf.ts` and
its tests. `fileLeafKind` — the *viewer* partition — stays; the two were
already documented as different partitions that must not be borrowed for each
other's job, and only one of them is being retired.

### What arrives

**`lib/components/knowledge/file-icon.ts`** — pure, tested:

- `fileIcon(label: string): NavIcon` — derives the extension from the label's
  own basename (which, after §2, is always the true filename) and maps it to a
  lucide component:

  | bucket | extensions | icon |
  |---|---|---|
  | prose | `.md .txt .rtf` | `FileText` |
  | source | `.ts .js .tsx .jsx .svelte .ex .exs .rs .py .rb .go .java .kt .swift .c .h .cpp .cs .php .sql` | `FileCode` |
  | shell | `.sh .bash .zsh .fish`, `Justfile`, `Makefile`, `Dockerfile` | `FileTerminal` |
  | data | `.json .yaml .yml .toml .xml .ini` | `FileBraces` |
  | tabular | `.csv .tsv .xlsx` | `FileSpreadsheet` |
  | image | `.png .jpg .jpeg .gif .webp .svg` | `FileImage` |
  | pdf | `.pdf` | `BookText` |
  | archive | `.zip .tar .gz` | `FileArchive` |
  | fallback | anything else, incl. extension-less | `File` |

  Icon names verified present in the installed `@lucide/svelte` — note it
  ships `file-braces`, **not** `file-json`.

- `folderIcon(open: boolean): NavIcon` — `FolderOpen` when expanded, `Folder`
  when collapsed.

### Placement

Every row gets exactly **one** glyph, in one column, at `size-3.5`,
`strokeWidth={1.5}`, `text-ink-meta` — the sidebar's stated icon treatment.

Folder rows **replace** the rotating `ChevronRight` with `Folder`/`FolderOpen`.
Open/closed is then carried by the glyph itself rather than by rotation;
`aria-expanded` is unchanged, so nothing is lost for assistive tech. The
trade is losing the rotation's motion cue and gaining a tree where files and
folders share one aligned icon rail — leaf labels currently start further left
than folder labels, and this fixes that as a side effect.

---

## 4. Right-click context menu

### Shell

`components/ui/context-menu/` is added through the shadcn-svelte CLI, the same
generated-component convention `dropdown-menu` already follows.

bits-ui's `ContextMenu` and `DropdownMenu` expose matching
`Root`/`Trigger`/`Content`/`Item`/`Separator` surfaces. So `EntryMenu.svelte`
gains a `variant: 'dropdown' | 'context'` prop and selects the primitive set at
the top of the component. **One item list, two shells** — the `⋯` overflow and
the right-click menu cannot drift apart, because there is only one of them.

`IcmTree` wraps each row in the context variant's trigger; the `⋯` button keeps
the dropdown variant. Right-click anywhere on a row opens the menu.

### Items

Ordered, kind-gated, separators between groups:

| item | folder | page | file | notes |
|---|---|---|---|---|
| Open in a new tab | — | ✓ | ✓ | only when the host passes `onOpenInTab`; carries the host's `openInTabDisabled` reason |
| Start a session with this page/file | — | ✓ | ✓ | existing `startSessionWithEntry` |
| Reveal in Finder / Explorer / file manager | ✓ | ✓ | ✓ | desktop only — hidden entirely in a browser |
| Copy path | ✓ | ✓ | ✓ | ICM-relative path, the form you hand the agent |
| Copy name | ✓ | ✓ | ✓ | basename |
| New page here / New folder here | ✓ | ✓ | ✓ | *inside* on a folder row, *alongside* on a leaf |
| Rename | ✓ | ✓ | ✓ | existing `RenameDialog` |
| Delete… | ✓ | ✓ | ✓ | existing `DeleteDialog` — already a modal confirmation |

**`lib/components/knowledge/entry-actions.ts`** — pure, tested. Given
`{ kind, canReveal, canOpenInTab, openInTabDisabled }` it returns the ordered
descriptor list (`{ id, label, destructive?, disabledReason? }` plus separator
markers). The two menu shells render whatever it returns, so the gating rules
are asserted in a unit test rather than by reading two component templates.

**Duplicate was dropped.** It is the only requested action with no backend
behind it — it would need `Valea.ICM.duplicate/2` (recursive for folders), an
Ash action, a codegen pass, and its own containment tests. Deferred rather
than rushed.

### Reveal in the OS file manager

- **Desktop crate:** `tauri-plugin-opener = "2"` in `Cargo.toml`,
  `.plugin(tauri_plugin_opener::init())` in `main.rs`, and
  `opener:allow-reveal-item-in-dir` in `capabilities/default.json` — that one
  permission and no other, so the plugin's URL-opening half stays unreachable
  and `links.rs` remains the only door to the browser.
- **Frontend:** `@tauri-apps/plugin-opener` and a new
  **`lib/shell/reveal-in-os.ts`** — `canRevealInOs()`, `revealInOs(abs)`
  (best-effort, never throws — the quiet posture `keychain.ts` and
  `external-link.ts` share), and `revealLabel()` returning "Reveal in Finder" /
  "Show in Explorer" / "Show in file manager" off `$lib/shell/platform.ts`.
  This becomes the **fourth** module allowed to touch Tauri IPC; `keychain.ts`'s
  boundary comment — the grep-able list — is updated to say so.
- **The absolute path** is the mount's `root` (already on `MountSummary`) joined
  with the node's ICM-relative path. A pure `absPathFor(mounts, mountKey, rel)`
  helper with tests, returning `null` for an unknown mount so the item is
  simply absent rather than aimed at a wrong path.
- **Browser mode** hides the item. The backend could shell out — it runs on the
  same machine — but that adds a process-exec surface for a convenience, and
  the desktop is where this is actually used.

### Copy path / Copy name

`navigator.clipboard.writeText` inside a `try/catch`; a failure is silent. Both
the Tauri webview and the browser support it on a secure/loopback origin.

### New page / New folder here

Reuses `NewEntryDialog` (`{ mode, mountKey, parentPath, open }`) — `parentPath`
is the row's own path for a folder, and its parent directory for a leaf.

---

## 5. The working indicator

### The stuck indicator: cause and fix

`busy` is a **client-side guess**.
[`agent-session.svelte.ts`](../../../frontend/src/lib/stores/agent-session.svelte.ts)
raises it on any `message`/`thought`/`tool` item and lowers it only on a `turn`
item. The server sends `busy` **once**, in the join reply, and never again.

So a `tool_call_update` that lands *after* its turn completed — which is
exactly what a subtask finishing out of band produces — re-raises `busy` with
no `turn` item left to come. The indicator stays lit until the channel is
rejoined. That matches the report precisely, including that it is
intermittent (it needs a late update) and that a reload clears it.

The server already holds the truth: `Connection.turn_in_flight?/1` — is a
`session/prompt` request still pending. Nothing consults it after join.

**Fix — make the backend authoritative:**

- `SessionServer` keeps the last broadcast busy value in state, recomputes
  `status == :running and Connection.turn_in_flight?(conn)` at the end of every
  reduction that can change it (frame handling, status transitions, prompt,
  cancel), and broadcasts `{:session_busy, bool}` **on change only**.
- `ValeaWeb.AgentSessionChannel` gains a `handle_info({:session_busy, busy},
  socket)` that pushes `"busy"`. The join reply is unchanged.
- `AgentSessionStore` subscribes to `"busy"` and **stops inferring**: the
  `message`/`thought`/`tool` rising edge and the `turn` falling edge are both
  deleted. What remains is the optimistic raise inside `prompt()` — so the box
  reacts to your own send without a round trip — and the `turn` item still
  driving `#flushQueue`, which is about the client queue, not about busy.

This retires the whole class of drift, not just the subtask case.

### Naming the work

Merging the two requested treatments into one control rather than building two
that say the same thing: the existing indicator line **becomes** the
expandable summary.

- **`lib/components/agent/activity.ts`** — pure, tested.
  `runningTools(items): { id, title }[]` returns tool items whose `status` is
  `pending` or `in_progress`, in first-arrival order.
  `activityLabel(running): string` returns the most recent running title, or
  `'Working…'` when there is none.
- **`Composer.svelte`** — the indicator keeps its bouncing dots and elapsed
  timer, and its text becomes `activityLabel(...)`, followed by `· N running`
  when more than one tool is in flight. When `running.length > 0` the line is a
  `<button>` that expands a list of the running titles beneath it; otherwise it
  is the static `role="status"` line it is today.
- **`ChatView`** passes `activity={runningTools(store.items)}`.

A spawned subtask arrives as an ordinary tool call carrying its own title, so
it appears in that list named, with no title-sniffing heuristic. ACP has no
subagent concept on the wire, and inventing one from title prefixes would be a
guess that breaks the first time the harness rewords a title. Listing every
running tool honestly is both simpler and more useful.

**Security:** tool titles are agent-authored. Plain Svelte interpolation only,
`{@html}` forbidden — the standing rule for everything under `agent/`.

---

## 6. Remembered composer options

**`lib/stores/composer-options.svelte.ts`** — `localStorage` key
`valea.composer-options`, shape `{ [workspaceId]: { [configWireId]: value } }`,
read and written through `persist.ts`'s guarded `readJson`/`writeJson`. Per
workspace, every chip.

Keyed on `configWireId(item)`, never `item.id` — the render id is
`config-`-prefixed for timeline uniqueness and is not what the adapter accepts.
`ChatView`'s `onSetConfig` already receives the wire id from `Composer`.

**Write:** `onSetConfig` calls `store.setConfigOption(...)` and
`composerOptions.remember(workspaceStore.id, configId, value)`.

**Apply — new sessions only.** `AgentSessionStore` gains
`opts.applyConfig?: Record<string, string>`. As each `config` item arrives, if
its wire id is still pending in that map, the value differs from `current`, and
the value is among the item's own options, the store pushes
`set_config_option` and drops the key. Each remembered option therefore fires
at most once, and a stale value — a model the adapter no longer offers — is
discarded rather than pushed and rejected.

`ChatView` passes `applyConfig` **only** for a session id it created in this
session of the app (a module-scope `Set` populated on `api.createAgentSession`
success). Resuming last week's thread keeps whatever configuration it had,
which is the behaviour you want when reopening old work.

The chip may visibly settle from the adapter default to the remembered value on
a fresh session. That is one render, it only happens when they differ, and the
alternative — blocking the composer until config settles — is worse.

---

## Testing

Pure logic is unit-tested, following the project's "extract the logic, no
component render harness" convention:

| module | what is pinned |
|---|---|
| `highlight/languages.ts` | extension and fence → grammar, aliases, unmapped → `null` |
| `knowledge/file-icon.ts` | every bucket, extension-less names, folder open/closed |
| `knowledge/entry-actions.ts` | kind gating, desktop gating, disabled reasons, order |
| `shell/reveal-in-os.ts` | absolute-path join, unknown mount → `null`, label per platform |
| `agent/activity.ts` | running filter, arrival order, label and count |
| `stores/composer-options.svelte.ts` | per-workspace isolation, round trip, absent/corrupt storage |
| `stores/agent-session.svelte.ts` | a late tool update after a turn no longer re-arms `busy`; a `"busy"` push sets it; queue still flushes on `turn` |
| `shell/nav.ts` | page labels carry `.md`; file and folder labels unchanged |
| `design/contrast.test.ts` | every code token at AA on `paper-track`, both themes |

Backend (ExUnit): `SessionServer` broadcasts busy on the rising and falling
edge and **not** on unchanged reductions; the channel pushes it.

## Manual verification

Things no test here covers:

1. Highlighting reads correctly in **both** themes, on a real `.ex`, `.ts`,
   `.json` and a 300 KB file (which must stay plain).
2. Right-click reaches the menu on every tree host — sidebar, Files pane,
   Knowledge route — and **not** in the two popover pickers (compose attach,
   session header), which pass no menus by design.
3. Reveal opens Finder with the file selected, on a path containing a space
   and a non-ASCII character.
4. The working indicator survives a turn that spawns subtasks, and clears when
   the turn ends.
5. A model chosen in workspace A does not leak into workspace B, and a resumed
   session keeps its own.
