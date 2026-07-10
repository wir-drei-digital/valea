# ICM Editor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the ICM editable: Notion-like tiptap editor over markdown files, deterministic server-side markdown↔ProseMirror conversion, version-guarded saves, and reference-aware tree CRUD.

**Architecture:** Markdown on disk stays the single source of truth. The backend converts md ↔ ProseMirror JSON (vendored magus converter, pure Elixir, MDEx-based); the SPA edits ProseMirror JSON in tiptap and saves through debounced RPC with a content-hash version guard. Tree writes (create/rename/delete) go through the existing containment chokepoint; rename updates workflow `sources:` references.

**Tech Stack:** Elixir/Phoenix/Ash + mdex ~> 0.7; tiptap 2.27.x on Svelte 5; ash_typescript RPC (constrained-map returns for all NEW actions).

**Reference documents (read before your task):**
- Spec: `docs/superpowers/specs/2026-07-10-icm-editor-design.md`
- Design system: `docs/DESIGN_SYSTEM.md` (§3 type, §4 buttons, §10 progressive disclosure)
- Donor repos (READ-ONLY): `/Users/daniel/Development/magus`, `/Users/daniel/Development/tiptap_phoenix`

## Global Constraints

- Markdown files are the source of truth; the frontend never parses/serializes markdown.
- **Determinism contract:** open-then-save of an untouched page writes NOTHING (dirty tracking); the converter round-trips every seed page byte-identically (`to_markdown(from_markdown(x)) == x`), enforced by test.
- All NEW RPC actions use **constrained map returns** (typed fields), never bare `:map`. Existing Phase-1 actions are not retro-typed.
- Every ICM write passes the existing containment chokepoint; writes are atomic (tmp file + rename in the same directory).
- Errors: `page_changed`, `not_found`, `name_invalid`, `already_exists`, `outside_workspace`, `workspace_not_open` — frontend maps each to calm copy (no exclamation marks), `role="alert"`.
- No dependency on the `tiptap_phoenix` package — vendored files only, each with an origin header comment.
- Token-only styling; Svelte 5 runes; editor body type Instrument Sans (Newsreader is chrome only).
- Test conventions: backend workspace tests `async: false`, tmp dirs `"valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"`, `on_exit` File.rm_rf! + Manager.close + VALEA_APP_DIR cleanup (mirror `backend/test/valea/icm_test.exs`).
- Commit after every task. `just test` green from Task 5 onward (codegen staleness gate).

---

### Task 1: Vendor the markdown ↔ ProseMirror converter

**Files:**
- Modify: `backend/mix.exs` (add `{:mdex, "~> 0.7"}`)
- Create: `backend/lib/valea/markdown/prose_mirror.ex`, `backend/lib/valea/markdown/prose_mirror/profile.ex`, `backend/lib/valea/markdown/profile.ex`
- Test: `backend/test/valea/markdown/prose_mirror_test.exs`, `backend/test/valea/markdown/determinism_test.exs`

**Interfaces:**
- Produces: `Valea.Markdown.ProseMirror.from_markdown(md, profile \\ Valea.Markdown.Profile)` → `{:ok, pm_map}`; `to_markdown(pm_map, profile \\ Valea.Markdown.Profile)` → `{:ok, md_string}`. `pm_map` is string-keyed ProseMirror JSON (`%{"type" => "doc", "content" => [...]}`).

- [ ] **Step 1: Vendor the source.** Copy `/Users/daniel/Development/magus/lib/magus/markdown/prose_mirror.ex` → `backend/lib/valea/markdown/prose_mirror.ex` and `/Users/daniel/Development/magus/lib/magus/markdown/prose_mirror/profile.ex` → `backend/lib/valea/markdown/prose_mirror/profile.ex`. Rename modules `Magus.Markdown.*` → `Valea.Markdown.*`. Add a header comment to each: `# Vendored from magus (lib/magus/markdown/...) on 2026-07-10 — keep divergences minimal.` Do NOT copy `Magus.Brain.ProseMirrorProfile` (magus-coupled).
- [ ] **Step 2: Write `backend/lib/valea/markdown/profile.ex`** — the minimal Valea profile implementing the `Valea.Markdown.ProseMirror.Profile` behaviour with no custom node lifting (CommonMark + GFM passthrough: headings, paragraphs, bullet/ordered lists, task lists, tables, code blocks, blockquotes, links, emphasis/strong/strikethrough, horizontal rules). Read the behaviour's callbacks after vendoring and implement each as the identity/default (magus's profile shows the pattern; strip everything referencing `magus://`, callouts, wikilinks, tags, image blocks). If the behaviour has optional callbacks with sane defaults, rely on them.
- [ ] **Step 3: Vendor + adapt the tests.** Copy `/Users/daniel/Development/magus/test/magus/markdown/prose_mirror_test.exs` → `backend/test/valea/markdown/prose_mirror_test.exs`, rename modules, DELETE test cases that exercise magus-specific profile features (callouts, wikilinks, tags, magus:// links, image blocks), keep the CommonMark/GFM matrix (headings, lists, task lists, tables, code fences, links, emphasis, blockquotes). Run: `cd backend && mix deps.get && mix test test/valea/markdown/` — iterate until green.
- [ ] **Step 4: Write the determinism test** — `backend/test/valea/markdown/determinism_test.exs` (async: true, no workspace needed — reads the template directly):

```elixir
defmodule Valea.Markdown.DeterminismTest do
  use ExUnit.Case, async: true

  alias Valea.Markdown.ProseMirror

  @template Path.join(:code.priv_dir(:valea), "workspace_template/icm")

  for path <- Path.wildcard(Path.join(Path.join(:code.priv_dir(:valea), "workspace_template/icm"), "**/*.md")) do
    rel = Path.relative_to(path, Path.join(:code.priv_dir(:valea), "workspace_template/icm"))

    test "round-trips seed page #{rel} byte-identically" do
      md = File.read!(unquote(path))
      {:ok, pm} = ProseMirror.from_markdown(md)
      {:ok, out} = ProseMirror.to_markdown(pm)
      # second pass must be a fixed point even if the first normalizes
      {:ok, pm2} = ProseMirror.from_markdown(out)
      {:ok, out2} = ProseMirror.to_markdown(pm2)
      assert out2 == out
      assert out == md,
             "seed page #{unquote(rel)} does not round-trip byte-identically; " <>
               "either fix the serializer or canonicalize the seed page in the same commit"
    end
  end

  test "template has seed pages (guard against silent wildcard miss)" do
    assert length(Path.wildcard(Path.join(@template, "**/*.md"))) >= 12
  end
end
```

- [ ] **Step 5: Make the determinism tests pass.** Two levers, in preference order: (a) fix serializer defaults so output matches the seed pages' existing style (bullet char, heading style, blank-line policy); (b) where MDEx canonicalization genuinely differs (e.g. trailing newline), canonicalize the seed page files in `backend/priv/workspace_template/icm/` in the same commit — content must stay semantically verbatim per the product brief (wording unchanged; only whitespace/list-marker normalization allowed, and record every such change in the report).
- [ ] **Step 6: Full suite + commit**

```bash
cd backend && mix test && mix format --check-formatted && mix compile --warnings-as-errors
git add -A && git commit -m "feat(backend): vendored deterministic markdown<->prosemirror converter (mdex)"
```

---

### Task 2: Page hash + save_page write operation

**Files:**
- Modify: `backend/lib/valea/icm.ex`
- Test: `backend/test/valea/icm_write_test.exs`

**Interfaces:**
- Consumes: `Valea.Markdown.ProseMirror` (Task 1); existing `Valea.ICM` read functions + `contain/2` chokepoint.
- Produces: `Valea.ICM.page/1` return map gains `hash` (lowercase hex SHA-256 of file bytes) and `prosemirror` (converted JSON map). `Valea.ICM.save_page(rel_path, pm_map, base_hash)` → `{:ok, %{hash: new_hash, saved_at: iso8601}} | {:error, :page_changed | :not_found | :outside_workspace | :no_workspace | term}`.

- [ ] **Step 1: Write failing tests** — `backend/test/valea/icm_write_test.exs` (async: false, standard workspace setup copied from `backend/test/valea/icm_test.exs`):

```elixir
# inside the module, after the standard setup block:
alias Valea.ICM
alias Valea.Markdown.ProseMirror

defp load(path) do
  {:ok, page} = ICM.page(path)
  page
end

test "page returns hash and prosemirror" do
  page = load("Offers/Founder Coaching Package.md")
  assert page.hash =~ ~r/^[0-9a-f]{64}$/
  assert %{"type" => "doc"} = page.prosemirror
end

test "save_page round-trips an edit and returns a new hash" do
  page = load("Policies/No Medical Advice.md")
  {:ok, pm} = ProseMirror.from_markdown(page.content <> "\nOne more line.\n")
  {:ok, %{hash: new_hash}} = ICM.save_page(page.path, pm, page.hash)
  refute new_hash == page.hash
  assert load(page.path).content =~ "One more line."
end

test "save_page rejects a stale base hash" do
  page = load("Policies/No Medical Advice.md")
  {:ok, pm} = ProseMirror.from_markdown("# Changed\n")
  {:ok, _} = ICM.save_page(page.path, pm, page.hash)
  assert {:error, :page_changed} = ICM.save_page(page.path, pm, page.hash)
end

test "save_page enforces containment and existence" do
  {:ok, pm} = ProseMirror.from_markdown("# X\n")
  assert {:error, :outside_workspace} = ICM.save_page("../logs/audit.jsonl", pm, String.duplicate("0", 64))
  assert {:error, :not_found} = ICM.save_page("Offers/Nope.md", pm, String.duplicate("0", 64))
end

test "unchanged save is byte-identical (determinism through the write path)" do
  page = load("Offers/Founder Coaching Package.md")
  {:ok, %{hash: h2}} = ICM.save_page(page.path, page.prosemirror, page.hash)
  assert h2 == page.hash
end
```

- [ ] **Step 2: Run to verify failure**, then implement in `backend/lib/valea/icm.ex`: extend `page/1`'s success map with `hash: sha256_hex(content)` and `prosemirror:` via `ProseMirror.from_markdown(content)` (a conversion failure returns `{:error, {:conversion_failed, msg}}` — loud, never a page without prosemirror). Add `save_page/3`: contain → `File.read` (`:enoent` → `:not_found`) → compare `sha256_hex(current) == base_hash` else `:page_changed` → `ProseMirror.to_markdown(pm_map)` → atomic write (`path <> ".tmp"`, `File.rename!`) → return new hash + `DateTime.utc_now() |> DateTime.to_iso8601()`. Private `sha256_hex/1` = `:crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)`.
- [ ] **Step 3: Tests green; full suite; commit** — `feat(backend): icm page hash + version-guarded atomic save`

---

### Task 3: Create page/folder + name validation

**Files:**
- Modify: `backend/lib/valea/icm.ex`
- Test: extend `backend/test/valea/icm_write_test.exs`

**Interfaces:**
- Produces: `Valea.ICM.create_page(parent_rel_path, name)` → `{:ok, %{path: rel}} | {:error, :name_invalid | :already_exists | ...}` (empty `parent_rel_path` = icm root; page seeded with `"# " <> title <> "\n"` where title = name sans `.md`); `Valea.ICM.create_folder(parent_rel_path, name)` same shape; `Valea.ICM.valid_name?(name)` (shared validation: non-empty after trim, no `/` or `\`, no leading `.`, NFC-normalized; for pages `.md` appended if absent).

- [ ] **Step 1: Failing tests** (same file, same conventions):

```elixir
test "create_page seeds title and appends .md" do
  {:ok, %{path: path}} = ICM.create_page("Decisions", "Pricing Call")
  assert path == "Decisions/Pricing Call.md"
  assert load(path).content == "# Pricing Call\n"
end

test "create_page at root, create_folder, duplicate and invalid names" do
  {:ok, %{path: "Scratch.md"}} = ICM.create_page("", "Scratch")
  {:ok, %{path: "Projects"}} = ICM.create_folder("", "Projects")
  assert {:error, :already_exists} = ICM.create_folder("", "Projects")
  assert {:error, :already_exists} = ICM.create_page("", "Scratch")
  for bad <- ["", "  ", "a/b", "a\\b", ".hidden"] do
    assert {:error, :name_invalid} = ICM.create_page("", bad)
    assert {:error, :name_invalid} = ICM.create_folder("", bad)
  end
  assert {:error, :outside_workspace} = ICM.create_page("..", "x")
end
```

- [ ] **Step 2: Implement** (`valid_name?/1` with `String.normalize(name, :nfc)`; create functions contain the parent, validate, check `File.exists?` → `:already_exists`, `File.mkdir_p`/atomic write). **Step 3: green + full suite + commit** — `feat(backend): icm create page/folder with name validation`

---

### Task 4: Reference scanner + rename/delete

**Files:**
- Create: `backend/lib/valea/icm/references.ex`
- Modify: `backend/lib/valea/icm.ex`
- Test: `backend/test/valea/icm/references_test.exs`, extend `backend/test/valea/icm_write_test.exs`

**Interfaces:**
- Produces: `Valea.ICM.References.referencing_workflows(rel_path)` → `{:ok, [%{file: "new_inquiry_triage.yaml", name: "New Inquiry Triage"}]}` (scans `{workspace}/workflows/*.yaml` for the literal string `icm/<rel_path>`; `name:` extracted by regex `~r/^name:\s*(.+)$/m`, falls back to filename); `Valea.ICM.References.rewrite(old_rel, new_rel)` → `{:ok, [updated_files]}` (string-replaces `icm/<old_rel>` → `icm/<new_rel>` in each referencing YAML, atomic write each). `Valea.ICM.rename(rel_path, new_name)` → `{:ok, %{path: new_rel, updated_workflows: [names]}}` (works for pages AND folders; folder rename rewrites references for every `.md` under it). `Valea.ICM.delete(rel_path)` → `{:ok, %{deleted: true}}` (file or folder recursive; does NOT touch workflows).

- [ ] **Step 1: Failing tests.** `references_test.exs` (workspace setup; the seeded `new_inquiry_triage.yaml` references 4 icm paths — the perfect fixture):

```elixir
test "finds workflows referencing a page" do
  {:ok, refs} = References.referencing_workflows("Offers/Founder Coaching Package.md")
  assert [%{file: "new_inquiry_triage.yaml", name: "New Inquiry Triage"}] = refs
  {:ok, []} = References.referencing_workflows("Clients/Lea Brunner.md")
end

test "rewrite updates the yaml literally and atomically" do
  {:ok, ["new_inquiry_triage.yaml"]} =
    References.rewrite("Tone & Voice/Email Tone Guide.md", "Tone & Voice/Voice Guide.md")
  yaml = File.read!(Path.join(ws_path(), "workflows/new_inquiry_triage.yaml"))
  assert yaml =~ "icm/Tone & Voice/Voice Guide.md"
  refute yaml =~ "icm/Tone & Voice/Email Tone Guide.md"
end
```

  In `icm_write_test.exs`: rename a referenced page → file moved, old gone, `updated_workflows == ["New Inquiry Triage"]`, YAML updated; rename to invalid/existing name → `:name_invalid`/`:already_exists`; rename a FOLDER containing a referenced page (rename `Offers` → `Offerings`) → YAML now says `icm/Offerings/Founder Coaching Package.md`; delete page → gone, workflows untouched; delete folder recursive.
- [ ] **Step 2: Implement** `References` (pure functions over the workspace path from `Manager.current/0`) and `rename`/`delete` in `Valea.ICM` (contain both old and new paths; `File.rename!`; folder case: collect `**/*.md` under it before rename, rewrite each old→new ref after). **Step 3: green + full suite + commit** — `feat(backend): reference-aware icm rename/delete`

---

### Task 5: RPC actions with constrained returns + codegen

**Files:**
- Modify: `backend/lib/valea/api/icm.ex`, `backend/lib/valea/api.ex`
- Regenerate: `frontend/src/lib/api/ash_rpc.ts` (+ `ash_types.ts`)
- Test: `backend/test/valea_web/icm_rpc_test.exs`

**Interfaces:**
- Consumes: Tasks 2–4 functions.
- Produces RPC actions (names exact; generated TS camelCase variants): `save_icm_page(path, prosemirror :map, base_hash)` → constrained `%{hash: :string, saved_at: :string}`; `create_icm_page(parent_path, name)` / `create_icm_folder(parent_path, name)` → `%{path: :string}`; `rename_icm_entry(path, new_name)` → `%{path: :string, updated_workflows: {:array, :string}}`; `delete_icm_entry(path)` → `%{deleted: :boolean}`; `icm_entry_references(path)` → `%{workflows: {:array, constrained %{file: :string, name: :string}}}`. Existing `icm_page` response gains `hash` + `prosemirror` (stays unconstrained — Phase-1 action, not retro-typed, but the two new FIELDS ride along in the map). Errors surface via the existing `Valea.Api.Error` (`page_changed`, `name_invalid`, `already_exists`, etc. as the error string).
- Constrained returns use Ash map constraints: `action :save_page, :map do constraints fields: [hash: [type: :string, allow_nil?: false], saved_at: [type: :string, allow_nil?: false]] ...` — consult `backend/deps/ash/documentation` for the exact map-constraints syntax in the installed Ash 3 version; the REQUIREMENT is that the generated TS for these actions is a typed interface, NOT `Record<string, any>` (verify in the regenerated `ash_rpc.ts`/`ash_types.ts` and quote the generated type in your report). If the installed ash_typescript cannot type constrained maps, STOP and report — do not ship more `Record<string, any>`.

- [ ] **Step 1: Failing RPC tests** (`icm_rpc_test.exs`, envelope per existing `backend/test/valea_web/rpc_test.exs` helpers): save round-trip via `/rpc/run` (load icm_page → mutate → save with hash → success; stale hash → `success: false` with `page_changed`); create/rename (assert `updatedWorkflows` non-empty for the referenced page)/delete/references happy paths.
- [ ] **Step 2: Implement** the six actions on `Valea.Api.ICM` (thin wrappers, existing error-mapping style) + `typescript_rpc` registrations in `Valea.Api`. Extend the existing `:page` action's return map with the two new fields (stringify prosemirror as-is — already string-keyed).
- [ ] **Step 3: Codegen + verify typing**

```bash
cd backend && mix ash_typescript.codegen
grep -A4 "SaveIcmPage" ../frontend/src/lib/api/*.ts   # expect typed fields, not Record<string, any>
cd ../frontend && bun run check
```

- [ ] **Step 4: `just test` green + commit** — `feat(api): icm write RPC surface with typed returns`

---

### Task 6: Frontend editor dependencies + vendored extensions + CSS re-theme

**Files:**
- Modify: `frontend/package.json`
- Create: `frontend/src/lib/editor/vendor/slash_command.js`, `bubble_menu.js`, `drag_handle.js`, `frontend/src/lib/editor/tiptap.css`

**Interfaces:**
- Produces: installed deps `@tiptap/core@^2.27.2, @tiptap/pm, @tiptap/starter-kit, @tiptap/suggestion, @tiptap/extension-{link,placeholder,typography,task-item,task-list,table,table-row,table-cell,table-header}, tippy.js@^6.3.7`; vendored factories `createSlashCommand({commands})`, `createBubbleMenu(opts)`, `DragHandle` importable from `$lib/editor/vendor/*`; `tiptap.css` with EVERY `--ttp-*` variable mapped to Paper & ink tokens.

- [ ] **Step 1:** `cd frontend && bun add @tiptap/core@^2.27.2 @tiptap/pm@^2.27.2 @tiptap/starter-kit@^2.27.2 @tiptap/suggestion@^2.27.2 @tiptap/extension-link@^2.27.2 @tiptap/extension-placeholder@^2.27.2 @tiptap/extension-typography@^2.27.2 @tiptap/extension-task-item@^2.27.2 @tiptap/extension-task-list@^2.27.2 @tiptap/extension-table@^2.27.2 @tiptap/extension-table-row@^2.27.2 @tiptap/extension-table-cell@^2.27.2 @tiptap/extension-table-header@^2.27.2 tippy.js@^6.3.7`
- [ ] **Step 2:** Copy the three files from `/Users/daniel/Development/tiptap_phoenix/assets/js/extensions/` into `frontend/src/lib/editor/vendor/`, header comment each: `// Vendored from tiptap_phoenix (assets/js/extensions/<name>) on 2026-07-10 — framework-agnostic, no LiveView coupling.` Read each after copying: strip any `pushEvent`-related option plumbing IF present in the copied file (the bubble menu takes a `pushEvent` opt in magus's usage — make it an optional generic callback or omit those buttons; slash command's `defaultCommands` — check whether they live in the extension file or magus; if magus-side, define Valea's own command list in Task 7).
- [ ] **Step 3:** Copy `/Users/daniel/Development/tiptap_phoenix/assets/css/tiptap.css` → `frontend/src/lib/editor/tiptap.css` (origin header). At the top, add a `:root`-scoped block assigning every `--ttp-*` variable the file consumes to Paper & ink tokens (`--ttp-*-bg` families → `var(--paper-*)`, text → `var(--ink-*)`, accent/primary → `var(--act)`, borders → `var(--paper-border)`/`--paper-chip-border`; selection/menu surfaces → `--paper-card` + `--shadow-card`). Grep the file for `--ttp-` to enumerate; every DaisyUI fallback must be overridden (no DaisyUI vars may remain live).
- [ ] **Step 4:** `bun run check && bun run build` green (nothing imports these yet — this task is inert plumbing). Commit — `feat(frontend): tiptap deps + vendored extensions + paper-ink editor css`

---

### Task 7: PageEditor component

**Files:**
- Create: `frontend/src/lib/components/editor/PageEditor.svelte`, `frontend/src/lib/editor/commands.ts`

**Interfaces:**
- Consumes: Task 6 vendor files/css; magus pattern reference `/Users/daniel/Development/magus/frontend/src/lib/components/brain/brain-editor.svelte` (READ-ONLY).
- Produces: `<PageEditor content={pmJson} onChange={() => ...} />` with exported methods `getJSON(): object`, `setContent(pmJson): void` (no onChange fire), `focus(): void`, `isEmpty(): boolean`. Extensions wired: StarterKit, Placeholder ("Write it the way you'd tell a new assistant…"), Link, Typography, TaskList+TaskItem (nested), Table family, createSlashCommand with `commands.ts` (heading 1–3, bullet/numbered/task list, table, quote, divider, code block — each `{title, icon?, run(editor)}`), createBubbleMenu (bold/italic/strike/link — no custom AI buttons this phase), DragHandle. Imports `../../editor/tiptap.css`.

- [ ] **Step 1:** Read the magus component once; build `PageEditor.svelte` on its lifecycle pattern: `let host: HTMLElement`, editor created in `$effect` wrapped `untrack(() => ...)`, destroyed in effect cleanup AND `onDestroy`; `onChange` prop called from the editor's `onUpdate`; content div class `tiptap-editor-content`.
- [ ] **Step 2:** Write `commands.ts` (pure data + editor commands; no store imports).
- [ ] **Step 3:** Verify: `bun run check` 0 errors; temporary mount on the knowledge page behind a `?editor=1` flag is allowed for eyeballing but MUST be removed before commit (the real wiring is Task 9). Commit — `feat(frontend): notion-like PageEditor (tiptap, magus pattern)`

---

### Task 8: Save-loop store (state machine)

**Files:**
- Create: `frontend/src/lib/stores/page-editor.svelte.ts`
- Modify: `frontend/src/lib/api/client.ts` (wrap the 6 new generated calls)
- Test: `frontend/src/lib/stores/page-editor.test.ts`

**Interfaces:**
- Consumes: generated client (Task 5) via `client.ts` (which stays the only ash_rpc importer): add `api.saveIcmPage(path, prosemirror, baseHash)`, `api.createIcmPage(parentPath, name)`, `api.createIcmFolder(parentPath, name)`, `api.renameIcmEntry(path, newName)`, `api.deleteIcmEntry(path)`, `api.icmEntryReferences(path)` — same `{ok,data}|{ok:false,error}` envelope as Phase 1.
- Produces: `PageEditorStore` class (constructor `(api, path, initial: {hash})`), states `'clean' | 'dirty' | 'saving' | 'conflict'`, fields `hash`, `savedAt`, `error`; methods `noteChange(getJson: () => object)` (marks dirty, arms 1000ms debounce), `flush()` (immediate save if dirty; awaited by route-leave and raw-toggle), `externalChange(newHash: string)` (clean → signals reload via `needsReload = true`; dirty+hash moved → `'conflict'`), `resolveReload()`, `resolveKeepMine()` (refetch hash via `api.icmPage`, resave own JSON). Debounce injectable (`tick` fn or timeout ms in constructor) for tests. Singleton-free — one instance per open page, created by the route.

- [ ] **Step 1: Failing tests** (fake api, fake timers): dirty→saving→clean happy path adopts returned hash; save returning `page_changed` → `'conflict'`; `flush()` awaits in-flight save; `externalChange` while clean sets `needsReload` without touching state; `resolveKeepMine` refetches then saves and lands clean; a change during `'saving'` re-arms (no lost edits); failed save (network) → stays dirty with `error`, next change retries.
- [ ] **Step 2: Implement** (runes class per `workspace.svelte.ts` conventions). **Step 3:** `bun run test && bun run check` green. Commit — `feat(frontend): page save-loop store with version guard + conflict states`

---

### Task 9: Page route rework (editor, toggle, meta line, banner)

**Files:**
- Modify: `frontend/src/routes/knowledge/[...path]/+page.svelte`
- Create: `frontend/src/lib/components/editor/ConflictBanner.svelte`, `frontend/src/lib/components/editor/PageMeta.svelte`

**Interfaces:**
- Consumes: `PageEditor` (T7), `PageEditorStore` (T8), existing `api.icmPage` (now returns `hash`+`prosemirror`), `wireIcmEvents`/icm store watcher pipeline (a page-level `$effect` watching `icmStore.nodes` changes may trigger `store.externalChange` — implement by refetching the page hash on `icm_changed`-driven nav refresh; simplest correct: on every icmStore refetch completion while this page is open, call `api.icmPage(path)` and compare hashes — note in code why).
- Produces: page view per spec — header row: mono breadcrumb · segmented pill **Friendly view | Raw** (999px pill on `bg-paper-track`, §4) · `PageMeta` (save status: "Saved · HH:MM" / "Saving…" / amber "Unsaved" / from store; context cost: `~N tokens` = `Math.round(content.length / 4)`, `text-ink-meta`); title; friendly = `PageEditor`, raw = existing read-only `<pre>` fed from a fresh `icm_page` fetch (raw always shows DISK content; toggling to raw first `await store.flush()`); `ConflictBanner` (amber suggestion-card style §6: "This page changed outside the editor." [Reload] [Keep mine]); ownership card unchanged. Route-leave: `flush()` in `onDestroy`/navigation hook. Folder view + not-found/skeleton branches unchanged.

- [ ] **Step 1:** Build the three pieces + wire the route (load → construct store with hash → render). Loading/error states preserved from Phase 1.
- [ ] **Step 2:** Live verification against `just dev` + a workspace: type in a page → "Saving…" → "Saved"; check the file on disk changed; `echo edit >> page.md` externally while clean → editor reloads; while dirty → banner; Keep mine wins; Reload shows external text; raw view matches disk; toggle flushes first. Record what you verified.
- [ ] **Step 3:** `bun run check && bun run test` green. Commit — `feat(frontend): editable knowledge page (friendly/raw, save status, conflicts)`

---

### Task 10: Tree CRUD UI

**Files:**
- Create: `frontend/src/lib/components/knowledge/NewEntryDialog.svelte`, `RenameDialog.svelte`, `DeleteDialog.svelte`, `EntryMenu.svelte`
- Modify: `frontend/src/routes/knowledge/+page.svelte`, `frontend/src/routes/knowledge/[...path]/+page.svelte` (folder view), `frontend/src/lib/components/shell/IcmTree.svelte` (overflow menu affordance)

**Interfaces:**
- Consumes: `api.createIcmPage/createIcmFolder/renameIcmEntry/deleteIcmEntry/icmEntryReferences` (T8's client wrappers); `encodePath` from `$lib/shell/nav`.
- Produces: "New page" / "New folder" quiet outline buttons (ListPane footer slot in `/knowledge` and folder views); `EntryMenu` (shadcn DropdownMenu — add the component via `bunx shadcn-svelte@latest add dropdown-menu` if absent) on list-pane rows and tree rows (hover-reveal ⋯, 32px hit target) with Rename / Delete; `RenameDialog` pre-fills current name and BEFORE confirm shows reference impact via `icmEntryReferences` ("Also updates 1 workflow that reads this page." — or nothing when zero); `DeleteDialog` warns per spec ("New Inquiry Triage reads this page — it will fail to find it." list + "This removes the file from your workspace folder."), destructive action styled terracotta-outline (§4 danger — never filled); errors mapped: `name_invalid` → "That name won't work as a file name. Avoid slashes and leading dots.", `already_exists` → "Something with that name is already there." Post-create: navigate to the new page (`/knowledge/<encodePath(path)>`) — editor focused; post-rename of the OPEN page: navigate to the new path; post-delete of the open page: navigate to `/knowledge`. Tree/list refresh rides the watcher (no optimistic surgery).

- [ ] **Step 1:** Build dialogs + menu + wire into the three surfaces.
- [ ] **Step 2:** Live verification: create page from list pane → lands in editor, nav updates; rename `Email Tone Guide.md` → dialog shows the workflow impact line, confirm → YAML on disk updated (check with grep), nav + URL updated; delete a referenced page → warning lists New Inquiry Triage; delete unreferenced → plain confirm. `bun run check && bun run test`.
- [ ] **Step 3:** Commit — `feat(frontend): icm tree crud with reference-aware dialogs`

---

### Task 11: Acceptance walkthrough + docs

**Files:**
- Modify: `docs/ARCHITECTURE.md`, `README.md` (only if drifted)

- [ ] **Step 1:** `just test` fully green.
- [ ] **Step 2:** Spec acceptance items, each with evidence: (1) edit Founder Coaching Package in tiptap → `git -C <workspace> diff`-style inspection shows a clean minimal markdown diff (workspace isn't git — compare with a pre-edit copy); (2) open a page, no edit, navigate away → file byte-identical (hash compare); (3) external edit while open → banner, Reload shows external content; (4) create → rename (YAML reference updated) → delete (warning) round-trip with live nav; (5) raw view matches disk exactly; (6) slash command, bubble menu, task list function; (7) context-cost estimate + save status visible.
- [ ] **Step 3:** ARCHITECTURE.md: add the converter (vendored provenance, determinism contract), ICM write ops + version guard, reference scanner, new RPC actions (note: first constrained/typed returns), editor component family. Surgical additions.
- [ ] **Step 4:** Commit — `chore: icm editor acceptance pass + architecture doc`

---

## Self-review notes (applied)

- Spec coverage: converter+determinism (T1), hash/save (T2), create+validation (T3), references/rename/delete (T4), typed RPC (T5), vendored extensions+css (T6), editor (T7), save loop+conflicts (T8), page view/toggle/meta/banner/token-cost (T9), CRUD UI+reference dialogs (T10), acceptance+docs (T11). Out-of-scope list respected (no wikilinks/images/history).
- Known adaptation points: Ash map-constraints DSL (T5, STOP condition), vendored file coupling cleanup (T6 Step 2), watcher→externalChange wiring detail (T9, in-code rationale required).
- Type consistency: store method names in T8 match T9 consumers; api wrapper names in T8 match T5 RPC names camelCased; `hash` field name uniform across T2/T5/T8/T9.
