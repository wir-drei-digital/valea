# Knowledge & Editor Depth (Spec C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship scan-backed search with a Cmd+K palette, standard-GFM page links with a `[[`/`@` picker and dangling-link create, backlinks unioned with workflow references, byte-surgical link rewriting on rename, page templates, and image paste/upload into mount-root `Assets/`.

**Architecture:** The filesystem is the index: `Valea.ICM.Search` and `Valea.ICM.Backlinks` scan enabled mounts on demand behind stable RPCs (FTS5 is the named later upgrade behind the same seam). Links are plain GFM on disk (relative inside the workspace, absolute when an external mount is involved); rename rewrites inbound destinations by in-place splice, never re-serializing referencing pages. Images travel over two small token-aware sidecar HTTP endpoints and live as ordinary files.

**Tech Stack:** Existing backend stack (MDEx ~> 0.7 for AST confirmation). Frontend adds one dependency: `@tiptap/extension-image` `^2.27.2`. No other new deps.

**Spec:** `docs/superpowers/specs/2026-07-12-knowledge-depth-design.md` — binding for every task.

## Global Constraints

- On disk, links and images are standard GFM only: `[text](dest)` / `![alt](dest)`, destination `<…>`-wrapped when it contains a space. Path rule: relative-from-the-linking-page when source and target are both inside the workspace; absolute physical path when either end is in an external mount.
- Determinism contract (editor spec) is inviolable: rename rewriting must change ONLY the destination bytes (plus `<>` wrapping when required) — referencing files are never round-tripped through the converter. Assert byte-equality outside the spliced spans in tests.
- Scans cover ENABLED, non-degraded mounts only (`Valea.Mounts.enabled/1`), embedded and external alike; result paths use the tree's vocabulary (workspace-relative embedded, absolute external). Per-mount scan budget 500 ms; a slow mount is skipped and named in the result notice.
- Search queries are literal text — no query syntax, no regex/FTS injection surface. AND semantics over whitespace-separated terms, case-insensitive; top 20 results.
- Templates: `Templates/` folder per mount; instantiation substitutes exactly `{{title}}` and `{{date}}` (ISO `YYYY-MM-DD`) textually (code fences included); unknown placeholders stay verbatim; template and new page must be in the SAME mount.
- Images: `Assets/<page-slug>-<hash8>.<ext>` at the target mount's root; upload POST is token-gated, capped 10 MB, extension+content-type allowlist `.png .jpg .jpeg .gif .webp` (no SVG — scriptable); the serve GET is read-only, mount-contained, image-extensions-only, and deliberately token-exempt (an `<img>` tag cannot send headers; the endpoint exposes only files local processes could already read, on a 127.0.0.1 listener).
- Never render agent/user content with `{@html}`. Copy tone calm, no exclamation marks.
- TDD per task; commit per task with trailer `Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>`. NEVER push to origin.
- Suite gates: `cd backend && mix test`; `just codegen` + `git diff --exit-code frontend/src/lib/api/` after RPC changes; `cd frontend && bun run check && bun run test`.
- This plan executes stacked on Spec B's branch; nothing here depends on B's code except starter-mount `AGENTS.md` (both append distinct sections) and the shared `DiffBlock` styling conventions.

---

### Task C1: `Valea.ICM.Search` — scan-backed full-text search

**Files:**
- Create: `backend/lib/valea/icm/search.ex`
- Test: `backend/test/valea/icm/search_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.enabled/1` (`[%{name, rel_root, root, ...}]`), `Valea.ICM.split_frontmatter/1` (public: `{block, body}`).
- Produces:

```elixir
Valea.ICM.Search.search(workspace, query, opts \\ [])
  :: {:ok, %{results: [result], skipped: [mount_name]}}
# result :: %{path, mount, title, snippet, terms}
# opts: mounts: [mount] (test injection), timeout_ms: (default 500), limit: (default 20)
```

`path` in tree vocabulary; `terms` = the downcased query terms (frontend re-finds them in the snippet for highlighting — no byte offsets across the wire).

- [ ] **Step 1: Failing tests**

```elixir
# backend/test/valea/icm/search_test.exs
defmodule Valea.ICM.SearchTest do
  use ExUnit.Case, async: false

  alias Valea.ICM.Search
  alias Valea.Workspace.Manager

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "valea-app-#{System.os_time(:nanosecond)}-#{System.unique_integer([:positive])}"
      )

    System.put_env("VALEA_APP_DIR", dir)
    Manager.close()
    {:ok, ws} = Manager.create(Path.join(dir, "workspaces"), "Primary")

    on_exit(fn ->
      Manager.close()
      File.rm_rf!(dir)
      System.delete_env("VALEA_APP_DIR")
    end)

    %{workspace: ws.path}
  end

  test "AND semantics across title and body, ranked title-first", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/Offers/Retainer.md"), "# Retainer\n\nMonthly coaching retainer.\n")
    File.write!(Path.join(ws, "mounts/primary/Clients/Note.md"), "# Note\n\nDiscussed a retainer with Julia.\n")

    {:ok, %{results: results}} = Search.search(ws, "retainer")
    paths = Enum.map(results, & &1.path)
    assert Enum.at(paths, 0) == "mounts/primary/Offers/Retainer.md"
    assert "mounts/primary/Clients/Note.md" in paths

    {:ok, %{results: both}} = Search.search(ws, "retainer julia")
    assert Enum.map(both, & &1.path) == ["mounts/primary/Clients/Note.md"]
  end

  test "workflow contracts are searchable; snippet carries the match", %{workspace: ws} do
    {:ok, %{results: results}} = Search.search(ws, "classify")
    assert Enum.any?(results, &String.contains?(&1.path, "Workflows/"))
    hit = Enum.find(results, &String.contains?(&1.path, "Workflows/"))
    assert String.downcase(hit.snippet) =~ "classify"
    assert hit.terms == ["classify"]
  end

  test "disabled mounts are excluded", %{workspace: ws} do
    {:ok, _} = Valea.Mounts.set_enabled("primary", false)
    {:ok, %{results: results}} = Search.search(ws, "coaching")
    assert results == []
    {:ok, _} = Valea.Mounts.set_enabled("primary", true)
  end

  test "a mount over budget is skipped and reported", %{workspace: ws} do
    {:ok, [mount]} = Valea.Mounts.enabled()
    {:ok, %{results: [], skipped: ["primary"]}} =
      Search.search(ws, "coaching", mounts: [mount], timeout_ms: 0)
  end

  test "empty and whitespace queries return nothing", %{workspace: ws} do
    assert {:ok, %{results: [], skipped: []}} = Search.search(ws, "   ")
  end

  test "regex metacharacters are literal text", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/Offers/Weird.md"), "# Weird\n\nprice (150) [draft]\n")
    {:ok, %{results: results}} = Search.search(ws, "(150)")
    assert Enum.map(results, & &1.path) == ["mounts/primary/Offers/Weird.md"]
  end
end
```

- [ ] **Step 2: Run** `cd backend && mix test test/valea/icm/search_test.exs` — FAIL (module undefined).

- [ ] **Step 3: Implement**

```elixir
# backend/lib/valea/icm/search.ex
defmodule Valea.ICM.Search do
  @moduledoc """
  Scan-backed full-text search over enabled mounts. The filesystem is the
  index (Spec C): per query, every mount is walked concurrently with a
  hard per-mount budget; a mount that does not answer in time is skipped
  and NAMED, never silently dropped. Query text is literal — terms are
  matched with `String.contains?/2` on downcased text, no pattern syntax.
  The RPC contract (`search/3`'s return shape) is deliberately
  implementation-agnostic: FTS5 can replace these internals later.
  """

  alias Valea.Mounts

  @default_timeout 500
  @default_limit 20
  @snippet_radius 90

  @spec search(String.t(), String.t(), keyword()) ::
          {:ok, %{results: [map()], skipped: [String.t()]}}
  def search(workspace, query, opts \\ []) do
    terms =
      query |> String.downcase() |> String.split(~r/\s+/u, trim: true) |> Enum.uniq()

    if terms == [] do
      {:ok, %{results: [], skipped: []}}
    else
      mounts = Keyword.get_lazy(opts, :mounts, fn -> Mounts.enabled(workspace) end)
      timeout = Keyword.get(opts, :timeout_ms, @default_timeout)
      limit = Keyword.get(opts, :limit, @default_limit)

      {hits, skipped} = scan_mounts(workspace, mounts, terms, timeout)

      results =
        hits
        |> Enum.sort_by(fn r -> {-r.score, r.path} end)
        |> Enum.take(limit)
        |> Enum.map(&Map.drop(&1, [:score]))

      {:ok, %{results: results, skipped: skipped}}
    end
  end

  defp scan_mounts(workspace, mounts, terms, timeout) do
    tasks =
      Enum.map(mounts, fn mount ->
        {mount.name, Task.async(fn -> scan_mount(workspace, mount, terms) end)}
      end)

    Enum.reduce(tasks, {[], []}, fn {name, task}, {hits, skipped} ->
      case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
        {:ok, mount_hits} -> {hits ++ mount_hits, skipped}
        _ -> {hits, skipped ++ [name]}
      end
    end)
  end

  defp scan_mount(workspace, mount, terms) do
    root = mount_root(workspace, mount)
    prefix = mount.rel_root || mount.root

    root
    |> Path.join("**/*.md")
    |> Path.wildcard()
    |> Enum.flat_map(fn abs ->
      case File.read(abs) do
        {:ok, content} -> score_file(prefix, root, abs, mount.name, content, terms)
        _ -> []
      end
    end)
  end

  defp mount_root(workspace, %{rel_root: rel}) when is_binary(rel), do: Path.join(workspace, rel)
  defp mount_root(_workspace, %{root: root}), do: root

  defp score_file(prefix, root, abs, mount_name, content, terms) do
    {_fm, body} = Valea.ICM.split_frontmatter(content)
    title = title_of(body, abs)
    headings = headings_of(body)

    title_down = String.downcase(title)
    headings_down = String.downcase(headings)
    body_down = String.downcase(body)

    if Enum.all?(terms, fn t ->
         String.contains?(title_down, t) or String.contains?(headings_down, t) or
           String.contains?(body_down, t)
       end) do
      score =
        Enum.reduce(terms, 0, fn t, acc ->
          acc +
            if(String.contains?(title_down, t), do: 5, else: 0) +
            if(String.contains?(headings_down, t), do: 3, else: 0) +
            occurrences(body_down, t)
        end)

      rel = Path.join(prefix, Path.relative_to(abs, root))

      [%{path: rel, mount: mount_name, title: title, snippet: snippet(body, body_down, terms), terms: terms, score: score}]
    else
      []
    end
  end

  defp occurrences(haystack, needle) do
    haystack |> :binary.matches(needle) |> length() |> min(10)
  end

  defp title_of(body, abs) do
    body
    |> String.split("\n")
    |> Enum.take(20)
    |> Enum.find_value(fn line ->
      case line do
        "# " <> rest -> String.trim(rest)
        _ -> nil
      end
    end)
    |> case do
      nil -> Path.basename(abs, ".md")
      t -> t
    end
  end

  defp headings_of(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, "#"))
    |> Enum.join("\n")
  end

  # Cut a window around the first body match; expand to whitespace
  # boundaries so we never split a grapheme or a word.
  defp snippet(body, body_down, terms) do
    pos =
      terms
      |> Enum.flat_map(fn t ->
        case :binary.match(body_down, t) do
          {p, _} -> [p]
          :nomatch -> []
        end
      end)
      |> Enum.min(fn -> 0 end)

    from = max(pos - @snippet_radius, 0)
    len = min(@snippet_radius * 2, byte_size(body) - from)

    body
    |> binary_part(from, len)
    |> trim_to_valid_utf8()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  # binary_part can cut mid-codepoint at either end — drop bytes until
  # both edges are valid UTF-8.
  defp trim_to_valid_utf8(bin) do
    bin |> trim_leading_invalid() |> trim_trailing_invalid()
  end

  defp trim_leading_invalid(<<_, rest::binary>> = bin) do
    if String.valid?(bin), do: bin, else: trim_leading_invalid(rest)
  end

  defp trim_leading_invalid(<<>>), do: <<>>

  defp trim_trailing_invalid(bin) do
    if String.valid?(bin) or byte_size(bin) == 0 do
      bin
    else
      trim_trailing_invalid(binary_part(bin, 0, byte_size(bin) - 1))
    end
  end
end
```

- [ ] **Step 4: Run** — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(backend): scan-backed ICM search with per-mount budgets"`

---

### Task C2: Search + paths-exist RPCs and client

**Files:**
- Modify: `backend/lib/valea/api/icm.ex` (actions `:search`, `:paths_exist`)
- Modify: `frontend/src/lib/api/client.ts` (`icmSearch`, `icmPathsExist` wrappers + field consts)
- Test: extend `backend/test/valea_web/icm_rpc_test.exs`

**Interfaces:**
- Produces:
  - RPC `icm_search(query, mount?)` → `{results: [{path, mount, title, snippet, terms}], skipped: [string]}` (`mount` arg filters `Mounts.enabled` to one name before scanning).
  - RPC `icm_paths_exist(paths: [string])` → `{results: [{path, exists: boolean}]}` — a path "exists" only when it attributes to an ENABLED mount (`Valea.Mounts.mount_for/2`) AND the file is a regular file inside it (containment via lexical prefix + `Valea.Paths.resolve_real/2` against the mount root, same shape as `MemoryProposal.check_target` — reuse that module: it is on the branch from Spec B). Anything else — shell paths, unknown mounts, traversal — reports `exists: false`, never an error. Booleans ride inside a typed array field (NOT top-level) so the ash_typescript falsy-map workaround is not needed; mirror `list_items`' constraints style.
  - Client: `api.icmSearch(query, mount?)`, `api.icmPathsExist(paths)`; field consts use the `as unknown as ...Fields` cast pattern for the typed-map arrays (see `icmTreeFields`).

- [ ] **Step 1: Failing RPC tests** — in `icm_rpc_test.exs` (mirror its existing action-driving helper): (a) `icm_search` for a seeded term returns a result with camelCased fields and the mount name; (b) `icm_paths_exist` with `["mounts/primary/Pricing/Current Pricing.md", "AGENTS.md", "mounts/primary/../secrets/x"]` → exists true/false/false.
- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** the two actions following the file's existing generic-action pattern (`argument`/`run`/`constraints fields`), with `error_for/1` reuse; then `just codegen`, add the client wrappers.
- [ ] **Step 4: Run** backend tests + codegen diff gate + `bun run check` — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat: icm search + paths-exist RPCs"`

---

### Task C3: Backlinks — AST-confirmed page inbound links, unified references RPC

**Files:**
- Create: `backend/lib/valea/icm/backlinks.ex`
- Modify: `backend/lib/valea/api/icm.ex` (`:references` action now returns `{workflows, pages}`)
- Modify: `frontend/src/lib/api/client.ts` (references field const)
- Test: `backend/test/valea/icm/backlinks_test.exs`, extend `icm_rpc_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.enabled/1`; MDEx (`MDEx.parse_document(md, extension: [table: true, tasklist: true, strikethrough: true])`; every node struct has a `:nodes` children list; links are `%MDEx.Link{url: url, nodes: children}`, images `%MDEx.Image{url: url, nodes: children}`, text `%MDEx.Text{literal: s}`).
- Produces: `Valea.ICM.Backlinks.backlinks(workspace, target_path) :: {:ok, [%{source_path, mount, link_text}]}` — target in tree vocabulary; sources sorted by path; confirmed by parsing (a prose mention that is not a link is NOT a backlink). RPC `:references` returns `%{workflows: [...existing...], pages: [%{source_path, mount, link_text}]}` — C10 updates the dialogs.

- [ ] **Step 1: Failing tests**

```elixir
# backend/test/valea/icm/backlinks_test.exs
defmodule Valea.ICM.BacklinksTest do
  use ExUnit.Case, async: false
  alias Valea.ICM.Backlinks
  alias Valea.Workspace.Manager

  setup do
    # standard tmp workspace setup (as in search_test.exs)
    ...
    %{workspace: ws.path}
  end

  test "relative link, angle-bracketed link, and image are confirmed; prose mention is not", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"

    File.write!(Path.join(ws, "mounts/primary/Offers/Ref1.md"),
      "# Ref1\n\nSee [pricing](<../Pricing/Current Pricing.md>).\n")

    File.write!(Path.join(ws, "mounts/primary/Ref2.md"),
      "# Ref2\n\n![shot](Pricing/Current Pricing.md)\n")

    File.write!(Path.join(ws, "mounts/primary/NotALink.md"),
      "# NotALink\n\nThe file Pricing/Current Pricing.md is mentioned in prose only.\n")

    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.map(links, & &1.source_path) ==
             ["mounts/primary/Offers/Ref1.md", "mounts/primary/Ref2.md"]
    assert Enum.at(links, 0).link_text == "pricing"
  end

  test "absolute destinations resolve too", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"
    abs = Path.join(ws, target)
    File.write!(Path.join(ws, "mounts/primary/Ref3.md"), "# Ref3\n\n[p](<#{abs}>)\n")
    {:ok, links} = Backlinks.backlinks(ws, target)
    assert Enum.any?(links, &(&1.source_path == "mounts/primary/Ref3.md"))
  end

  test "http and anchor destinations are ignored", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/Ref4.md"),
      "# Ref4\n\n[x](https://example.com/Current Pricing.md) [y](#current-pricing)\n")
    {:ok, links} = Backlinks.backlinks(ws, "mounts/primary/Pricing/Current Pricing.md")
    refute Enum.any?(links, &(&1.source_path == "mounts/primary/Ref4.md"))
  end
end
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement**

```elixir
# backend/lib/valea/icm/backlinks.ex
defmodule Valea.ICM.Backlinks do
  @moduledoc """
  Inbound page links for a target: cheap filename substring pre-filter
  across enabled mounts, then AST confirmation — only real Link/Image
  destinations that resolve to the target count (the References trick,
  generalized; prose mentions and code fences never match, because they
  are not Link nodes).
  """

  alias Valea.Mounts

  @mdex_extensions [table: true, tasklist: true, strikethrough: true]

  @spec backlinks(String.t(), String.t()) :: {:ok, [map()]}
  def backlinks(workspace, target_path) do
    target_abs = to_abs(workspace, target_path)
    needle = Path.basename(target_path)

    links =
      for mount <- Mounts.enabled(workspace),
          root = mount_root(workspace, mount),
          prefix = mount.rel_root || mount.root,
          abs <- Path.wildcard(Path.join(root, "**/*.md")),
          {:ok, content} <- [File.read(abs)],
          String.contains?(content, needle),
          source_rel = Path.join(prefix, Path.relative_to(abs, root)),
          source_rel != target_path,
          text <- confirmed_link_texts(workspace, source_rel, content, target_abs) do
        %{source_path: source_rel, mount: mount.name, link_text: text}
      end

    {:ok, Enum.sort_by(links, & &1.source_path)}
  end

  @doc "All Link/Image destinations of `content`, resolved to absolute paths, with their text."
  @spec destinations(String.t(), String.t(), String.t()) :: [%{url: String.t(), abs: String.t(), text: String.t()}]
  def destinations(workspace, source_rel, content) do
    case MDEx.parse_document(content, extension: @mdex_extensions) do
      {:ok, doc} ->
        source_dir = Path.dirname(to_abs(workspace, source_rel))

        doc
        |> walk([])
        |> Enum.flat_map(fn
          %MDEx.Link{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          %MDEx.Image{url: url} = n -> dest_entry(url, source_dir, plain_text(n))
          _ -> []
        end)

      _ ->
        []
    end
  end

  defp confirmed_link_texts(workspace, source_rel, content, target_abs) do
    workspace
    |> destinations(source_rel, content)
    |> Enum.filter(&(&1.abs == target_abs))
    |> Enum.map(& &1.text)
    |> case do
      [] -> []
      texts -> [hd(texts)]
    end
  end

  defp dest_entry(url, source_dir, text) do
    cond do
      not is_binary(url) or url == "" -> []
      String.starts_with?(url, ["http://", "https://", "mailto:", "#"]) -> []
      String.starts_with?(url, "/") -> [%{url: url, abs: Path.expand(url), text: text}]
      true -> [%{url: url, abs: Path.expand(url, source_dir), text: text}]
    end
  end

  # Version-proof manual AST walk: every MDEx node struct carries :nodes.
  defp walk(%{nodes: children} = node, acc) when is_list(children) do
    Enum.reduce(children, [node | acc], &walk/2)
  end

  defp walk(node, acc), do: [node | acc]

  defp plain_text(node) do
    node
    |> walk([])
    |> Enum.flat_map(fn
      %MDEx.Text{literal: s} -> [s]
      %MDEx.Code{literal: s} -> [s]
      _ -> []
    end)
    |> Enum.reverse()
    |> Enum.join()
    |> String.trim()
  end

  defp mount_root(workspace, %{rel_root: rel}) when is_binary(rel), do: Path.join(workspace, rel)
  defp mount_root(_workspace, %{root: root}), do: root

  defp to_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(workspace, rel), do: Path.expand(rel, workspace)
end
```

Note: `MDEx.Document` has a top-level `nodes:` list, so `walk/2` handles it via the same clause. If a struct name differs at compile time (e.g. `%MDEx.Code{}` fields), check `h MDEx.Document` locally and adjust the text-collection clauses — the tests pin behavior, not struct names.

RPC: extend `:references` to run both `References.referencing_workflows/1` and `Backlinks.backlinks/2` and return `%{workflows: ..., pages: ...}` with typed constraints (`pages: [{source_path, mount, link_text}]`, cast pattern in client). `just codegen`, update `icmEntryReferencesFields`.

- [ ] **Step 4: Run** backend tests + codegen gate + frontend check — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat(backend): AST-confirmed page backlinks; unified references RPC"`

---

### Task C4: Byte-surgical link rewrite on rename + shared splice + `<>` destination serialization

**Files:**
- Create: `backend/lib/valea/icm/link_rewrite.ex`, `backend/lib/valea/paths.ex` gains `relative/2`
- Modify: `backend/lib/valea/icm/references.ex` (extract `splice/3` → `Valea.ICM.Splice`, delegate), create `backend/lib/valea/icm/splice.ex`
- Modify: `backend/lib/valea/icm.ex` (`rename/2` collects ALL child files for link pairs; calls `LinkRewrite`; returns `updated_pages`), `backend/lib/valea/api/icm.ex` (`:rename` return adds `updated_pages`)
- Modify: `backend/lib/valea/markdown/prose_mirror.ex` (`link_href/1` + image serialization wrap destinations containing spaces in `<>`)
- Test: `backend/test/valea/icm/link_rewrite_test.exs`, extend `icm_write_test.exs`, `prose_mirror_test.exs`
- Modify: `frontend/src/lib/api/client.ts` (rename fields const)

**Interfaces:**
- Consumes: C3 `Backlinks.destinations/3` (AST confirmation set); `Valea.ICM.Splice.splice(content, matches, replacement)` (right-to-left, extracted verbatim from References).
- Produces:
  - `Valea.Paths.relative(from_dir, to_path) :: String.t()` — pure lexical relative path between two same-vocabulary paths (both workspace-relative or both absolute): drop the common prefix segments, `".."` per remaining `from_dir` segment, join with the remaining target segments.
  - `Valea.ICM.LinkRewrite.rewrite_all(workspace, pairs) :: {:ok, [updated_source_paths]} | {:error, {:rewrite_failed, file, reason}}` where `pairs :: [{old_path, new_path}]` in tree vocabulary.
  - `Valea.ICM.rename/2` returns `{:ok, %{path, updated_workflows, updated_pages}}`; RPC mirrors it.
  - Converter: `to_markdown` emits `](<dest>)` / `![alt](<dest>)` when dest contains a space; `from_markdown` already parses `<>` destinations (MDEx native) — round-trip determinism tests prove it.

- [ ] **Step 1: Failing converter tests** (in `prose_mirror_test.exs`): (a) `from_markdown("[a b](<Offers/My Page.md>)") |> to_markdown()` reproduces the input byte-for-byte; (b) a link mark with `href: "Offers/My Page.md"` serializes to `[x](<Offers/My Page.md>)`; (c) hrefs without spaces stay unwrapped (existing fixtures must not churn — the seed-page round-trip suite is the real gate).

- [ ] **Step 2: Implement converter wrapping** — in `link_href/1` (and the image `src`/serialization clauses `node_to_markdown_default image` + `inline_node_body_default image`):

```elixir
  defp wrap_dest(dest) do
    if is_binary(dest) and String.contains?(dest, " "), do: "<" <> dest <> ">", else: dest
  end
```

apply `wrap_dest/1` at every destination interpolation site. Run the FULL determinism suite (`mix test test/valea/markdown/`) — zero churn expected because no existing seed page has a spaced destination; if MDEx normalizes `<...>` away on parse (url comes back unbracketed), the wrap-on-serialize direction is exactly what restores it.

- [ ] **Step 3: Failing rewrite tests**

```elixir
# backend/test/valea/icm/link_rewrite_test.exs — standard tmp-workspace setup
  test "rename rewrites only the destination bytes", %{workspace: ws} do
    target = "mounts/primary/Pricing/Current Pricing.md"
    src = "mounts/primary/Offers/Uses Pricing.md"

    body = "# Uses\n\nBefore [pricing](<../Pricing/Current Pricing.md>) after.\n\n```\n](../Pricing/Current Pricing.md) in a fence stays\n```\n"
    File.write!(Path.join(ws, src), body)

    {:ok, %{updated_pages: [^src]}} = Valea.ICM.rename(target, "Rates.md")

    after_bytes = File.read!(Path.join(ws, src))
    assert after_bytes ==
             "# Uses\n\nBefore [pricing](<../Pricing/Rates.md>) after.\n\n```\n](../Pricing/Current Pricing.md) in a fence stays\n```\n"
  end

  test "unbracketed and image destinations; new name with a space gains brackets", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/A.md"), "# A\n\n![x](Pricing/Rates.md)\n")
    {:ok, _} = Valea.ICM.rename("mounts/primary/Pricing/Rates.md", "Rate Card.md")
    assert File.read!(Path.join(ws, "mounts/primary/A.md")) ==
             "# A\n\n![x](<Pricing/Rate Card.md>)\n"
  end

  test "folder rename rewrites inbound links to children", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/B.md"),
      "# B\n\n[t](Tone & Voice/Email Tone Guide.md)\n")
    {:ok, _} = Valea.ICM.rename("mounts/primary/Tone & Voice", "Voice")
    assert File.read!(Path.join(ws, "mounts/primary/B.md")) ==
             "# B\n\n[t](Voice/Email Tone Guide.md)\n"
  end

  test "cross-mount inbound links are rewritten too", %{workspace: ws} do
    {:ok, _} = Valea.Mounts.create(ws, "second", %{})  # use the real create/3 signature — check mounts.ex
    File.write!(Path.join(ws, "mounts/second/C.md"),
      "# C\n\n[p](../primary/Pricing/Current Pricing.md)\n")
    {:ok, _} = Valea.ICM.rename("mounts/primary/Pricing/Current Pricing.md", "Rates.md")
    assert File.read!(Path.join(ws, "mounts/second/C.md")) ==
             "# C\n\n[p](../primary/Pricing/Rates.md)\n"
  end
```

(Adjust the second-mount creation call to `Valea.Mounts.create/3`'s real signature — read it first; if scaffolding a second mount is heavyweight, create `mounts/second/icm.yaml` by hand with `Valea.Mounts.Manifest.write!/2`.)

- [ ] **Step 4: Implement.**

`Valea.ICM.Splice` — move References' `splice/3` verbatim (public, `@moduledoc false`), References delegates to it.

`Valea.Paths.relative/2`:

```elixir
  @doc """
  Lexical relative path from `from_dir` to `to_path` (same vocabulary on
  both sides). Pure segment math — no filesystem access.
  """
  @spec relative(String.t(), String.t()) :: String.t()
  def relative(from_dir, to_path) do
    from = Path.split(from_dir)
    to = Path.split(to_path)
    {common_from, common_to} = drop_common(from, to)
    Path.join(List.duplicate("..", length(common_from)) ++ common_to)
  end

  defp drop_common([h | t1], [h | t2]), do: drop_common(t1, t2)
  defp drop_common(from, to), do: {from, to}
```

`Valea.ICM.LinkRewrite`:

```elixir
defmodule Valea.ICM.LinkRewrite do
  @moduledoc """
  Rewrites inbound in-content link/image destinations when a page or
  folder is renamed — byte-surgically: only the destination bytes (plus
  `<>` wrapping when the new destination needs it) change; the file is
  never round-tripped through the converter, so the determinism contract
  holds. Occurrences are confirmed against the file's parsed Link/Image
  destinations, so code-fence lookalikes are untouched.
  """

  alias Valea.ICM.{Backlinks, Splice}
  alias Valea.Mounts

  @spec rewrite_all(String.t(), [{String.t(), String.t()}]) ::
          {:ok, [String.t()]} | {:error, {:rewrite_failed, String.t(), term()}}
  def rewrite_all(workspace, pairs) do
    sources =
      for mount <- Mounts.enabled(workspace),
          root = mount_root(workspace, mount),
          prefix = mount.rel_root || mount.root,
          abs <- Path.wildcard(Path.join(root, "**/*.md")),
          do: {Path.join(prefix, Path.relative_to(abs, root)), abs}

    renamed = MapSet.new(pairs, fn {old, _new} -> old end)

    Enum.reduce_while(sources, {:ok, []}, fn {source_rel, abs}, {:ok, updated} ->
      # A renamed file's inbound links are looked up under its OLD path in
      # `sources` only if the wildcard ran before the fs rename — rename/2
      # calls us AFTER moving, so sources reflect the new tree. Skip files
      # that are themselves rename targets only for self-reference safety.
      _ = renamed

      case rewrite_file(workspace, source_rel, abs, pairs) do
        :unchanged -> {:cont, {:ok, updated}}
        {:ok, _} -> {:cont, {:ok, updated ++ [source_rel]}}
        {:error, reason} -> {:halt, {:error, {:rewrite_failed, Path.basename(abs), reason}}}
      end
    end)
    |> case do
      {:ok, updated} -> {:ok, Enum.sort(updated)}
      err -> err
    end
  end

  defp rewrite_file(workspace, source_rel, abs, pairs) do
    with {:ok, content} <- File.read(abs) do
      confirmed = confirmed_urls(workspace, source_rel, content, pairs)

      case splice_urls(content, confirmed) do
        ^content -> :unchanged
        new_content -> atomic_write(abs, new_content)
      end
    end
  end

  # For every (old→new) pair, find this source's parsed destinations that
  # resolve to the OLD absolute target; map each matched url string to its
  # replacement destination string.
  defp confirmed_urls(workspace, source_rel, content, pairs) do
    dests = Backlinks.destinations(workspace, source_rel, content)
    source_dir = Path.dirname(source_rel)

    for {old, new} <- pairs,
        old_abs = to_abs(workspace, old),
        %{url: url} <- dests,
        Path.expand(url, Path.dirname(to_abs(workspace, source_rel))) == old_abs or
          (String.starts_with?(url, "/") and Path.expand(url) == old_abs),
        into: %{} do
      {url, replacement(url, source_dir, old, new, workspace)}
    end
  end

  defp replacement("/" <> _, _source_dir, _old, new, workspace),
    do: to_abs(workspace, new)

  defp replacement(_url, source_dir, _old, new, _workspace),
    do: Valea.Paths.relative(source_dir, new)

  # Replace each confirmed url occurrence INSIDE link syntax only:
  # `](url)` / `](<url>)` (image `![alt](` ends with the same `](`).
  defp splice_urls(content, confirmed) do
    Enum.reduce(confirmed, content, fn {url, new_dest}, acc ->
      acc
      |> splice_form("](<" <> url <> ">)", "](<" <> new_dest <> ">)")
      |> splice_form("](" <> url <> ")", "](" <> wrap(new_dest) <> ")")
    end)
  end

  defp splice_form(content, old_frag, new_frag) do
    case :binary.matches(content, old_frag) do
      [] -> content
      matches -> Splice.splice(content, matches, new_frag)
    end
  end

  defp wrap(dest), do: if(String.contains?(dest, " "), do: "<" <> dest <> ">", else: dest)

  defp atomic_write(abs, bytes) do
    tmp = abs <> ".tmp"
    with :ok <- File.write(tmp, bytes), do: File.rename(tmp, abs)
  end

  defp mount_root(workspace, %{rel_root: rel}) when is_binary(rel), do: Path.join(workspace, rel)
  defp mount_root(_workspace, %{root: root}), do: root

  defp to_abs(_workspace, "/" <> _ = abs), do: Path.expand(abs)
  defp to_abs(workspace, rel), do: Path.expand(rel, workspace)
end
```

Known limitation (document in the moduledoc, mirroring References' honesty): the SAME destination string appearing both as a real link and inside a code fence in ONE file is rewritten in both places — the AST confirms the file has a real link with that url, and the splice is textual. Acceptable; the fence-only case (test 1) is protected because confirmation fails for the whole file.

`Valea.ICM.rename/2` integration: where `do_rename` collects children, additionally collect ALL regular files (not just `.md`) into `link_pairs` (page rename → single pair). After the existing workflow-reference rewrite, call `LinkRewrite.rewrite_all(workspace, link_pairs)`; merge into the return: `{:ok, %{path: new_rel, updated_workflows: wfs, updated_pages: pages}}`. RPC `:rename` adds `updated_pages: {:array, :string}` to constraints; regenerate + update the client's field const.

- [ ] **Step 5: Run** all backend tests (determinism suite included) + codegen gate — PASS.
- [ ] **Step 6: Commit** — `git commit -m "feat(backend): byte-surgical page-link rewrite on rename; <> destination serialization"`

---

### Task C5: Templates — instantiation backend + starter content

**Files:**
- Modify: `backend/lib/valea/icm.ex` (`create_page_from_template/3`), `backend/lib/valea/api/icm.ex` (action `:create_page_from_template`)
- Create: `backend/priv/workspace_template/mounts/starter/Templates/Client.md`, `.../Templates/Decision.md`
- Modify: `backend/priv/workspace_template/mounts/starter/AGENTS.md` (Templates convention line)
- Modify: `frontend/src/lib/api/client.ts` (wrapper)
- Test: extend `backend/test/valea/icm_write_test.exs`, `icm_rpc_test.exs`, scaffold test

**Interfaces:**
- Produces: `Valea.ICM.create_page_from_template(parent_rel, name, template_rel) :: {:ok, %{path}} | {:error, :name_invalid | :already_exists | :template_not_found | :cross_mount_template | :outside_workspace | :no_workspace}` — substitutes `{{title}}` (page name sans `.md`) and `{{date}}` (`Date.utc_today() |> Date.to_iso8601()`) textually; template and parent must attribute to the same mount. RPC `create_page_from_template(parent_path, name, template_path)` → `{path}`.

- [ ] **Step 1: Failing tests**

```elixir
  test "create_page_from_template substitutes title and date, code fences included", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/Templates/T.md"),
      "# {{title}}\n\nSince {{date}}.\n\n```\n{{title}} in a fence\n```\n\n{{unknown}} stays\n")

    {:ok, %{path: path}} =
      Valea.ICM.create_page_from_template("mounts/primary/Clients", "Anna Roth", "mounts/primary/Templates/T.md")

    assert path == "mounts/primary/Clients/Anna Roth.md"
    today = Date.utc_today() |> Date.to_iso8601()
    assert File.read!(Path.join(ws, path)) ==
             "# Anna Roth\n\nSince #{today}.\n\n```\nAnna Roth in a fence\n```\n\n{{unknown}} stays\n"
  end

  test "cross-mount template is rejected", %{workspace: ws} do
    # second mount as in C4's test
    assert {:error, :cross_mount_template} =
             Valea.ICM.create_page_from_template("mounts/primary/Clients", "X", "mounts/second/Templates/T.md")
  end

  test "existing target and bad names are rejected as create_page does", %{workspace: ws} do
    File.write!(Path.join(ws, "mounts/primary/Templates/T.md"), "# {{title}}\n")
    assert {:error, :name_invalid} =
             Valea.ICM.create_page_from_template("mounts/primary/Clients", "a/b", "mounts/primary/Templates/T.md")
  end
```

- [ ] **Step 2: Run** — FAIL.
- [ ] **Step 3: Implement** in `icm.ex`, following `create_page/2`'s structure exactly (same name validation/normalization, same parent containment, same exists guard, same atomic write), plus: resolve+contain the template path (via `mount_root_for/1` + `contain/2`), compare template's mount to parent's mount (`Mounts.mount_for/2` on both — different name → `:cross_mount_template`; template unreadable → `:template_not_found`), then:

```elixir
    title = Path.basename(ensure_md_extension(name), ".md")
    content =
      template_bytes
      |> String.replace("{{title}}", title)
      |> String.replace("{{date}}", Date.utc_today() |> Date.to_iso8601())
```

RPC action mirrors `:create_page` with the extra `template_path` argument. `just codegen`, client wrapper `createIcmPageFromTemplate(parentPath, name, templatePath)`.

Starter content — `Templates/Client.md`:

```markdown
# {{title}}

- Since: {{date}}
- Status: prospect
- Contact:

## Context

What they do, what they came for, what matters to them.

## Sessions

| date | focus | notes |
| --- | --- | --- |

## Agreements

Pricing, cadence, boundaries agreed with this client.
```

`Templates/Decision.md`:

```markdown
# {{title}}

- Date: {{date}}
- Status: decided

## The decision

One or two sentences: what was decided.

## Why

The reasoning, and what prompted it.

## Where it applies

Pages this decision touches (pricing, policies, tone).
```

Mount `AGENTS.md` — extend the map section:

```markdown
- `Templates/` — starting points for new pages (`{{title}}` and
  `{{date}}` are filled in at creation). Use them when creating client
  files or decision entries so pages stay consistent.
```

- [ ] **Step 4: Run** backend + codegen gate + scaffold test — PASS.
- [ ] **Step 5: Commit** — `git commit -m "feat: page templates — instantiation RPC + starter Client/Decision templates"`

---

### Task C6: Image upload/serve HTTP endpoints

**Files:**
- Create: `backend/lib/valea_web/controllers/files_controller.ex`
- Modify: `backend/lib/valea_web/router.ex` (scope `/files`), `backend/lib/valea_web/endpoint.ex` (`Plug.Parsers` `length: 12_000_000`)
- Test: `backend/test/valea_web/files_controller_test.exs`

**Interfaces:**
- Consumes: `Valea.Mounts.mount_for/2`, `Valea.Paths.resolve_real/2`, C4's `Valea.Paths.relative/2`.
- Produces:
  - `POST /files/upload` (pipeline with `ValeaWeb.Plugs.ControlToken` — mirror the `:rpc` pipeline) — multipart fields `file` (`%Plug.Upload{}`) + `page_path` (the page the image is being inserted into, tree vocabulary). Validates: page attributes to an enabled mount; upload ≤ 10 MB (explicit `File.stat` check on the upload's tmp path — the parser cap is the transport backstop); extension AND `content_type` in the allowlist (`.png image/png`, `.jpg/.jpeg image/jpeg`, `.gif image/gif`, `.webp image/webp`). Writes `<mount-root>/Assets/<slug>-<hash8><ext>` (slug = page basename sans `.md`, downcased, non-alphanumerics → `-`, collapsed; hash8 = first 8 hex of sha256(bytes) — same bytes dedupe to the same name; existing file with same name+bytes is success). Responds `200 {"path": <tree-vocab path>, "rel_from_page": <relative dest from the page's dir>}`, errors `{"error": "..."}` with 400/413/401.
  - `GET /files/raw?path=<tree-vocab path>` — token-EXEMPT (see Global Constraints rationale); serves only regular files with allowlisted image extensions that attribute to an enabled mount and pass containment (lexical prefix + `resolve_real` under the mount root); correct `content-type`; anything else 404 (never 500, never a traversal echo).

- [ ] **Step 1: Failing controller tests** (use the app's ConnCase pattern — mirror `queue_rpc_test.exs`'s conn setup; token header helper from the rpc tests):

```elixir
  test "upload lands in Assets and serve returns it", %{conn: conn, workspace: ws} do
    upload = %Plug.Upload{
      path: write_tmp_png!(),
      filename: "shot.png",
      content_type: "image/png"
    }

    conn1 =
      conn
      |> put_req_header("x-valea-token", "valea-dev-token")
      |> post("/files/upload", %{
        "file" => upload,
        "page_path" => "mounts/primary/Clients/Julia Steiner.md"
      })

    assert %{"path" => path, "rel_from_page" => rel} = json_response(conn1, 200)
    assert path =~ ~r|^mounts/primary/Assets/julia-steiner-[0-9a-f]{8}\.png$|
    assert rel == "../" <> String.replace_prefix(path, "mounts/primary/", "")
    assert File.exists?(Path.join(ws, path))

    conn2 = get(build_conn(), "/files/raw", %{"path" => path})
    assert response(conn2, 200)
    assert get_resp_header(conn2, "content-type") |> hd() =~ "image/png"
  end

  test "upload without token is 401; bad type is 400; traversal serve is 404", %{conn: conn} do
    upload = %Plug.Upload{path: write_tmp_png!(), filename: "x.png", content_type: "image/png"}
    assert conn |> post("/files/upload", %{"file" => upload, "page_path" => "mounts/primary/a.md"}) |> response(401)

    bad = %Plug.Upload{path: write_tmp_png!(), filename: "x.svg", content_type: "image/svg+xml"}
    conn3 =
      conn |> put_req_header("x-valea-token", "valea-dev-token")
      |> post("/files/upload", %{"file" => bad, "page_path" => "mounts/primary/Clients/Julia Steiner.md"})
    assert json_response(conn3, 400)

    assert build_conn() |> get("/files/raw", %{"path" => "mounts/primary/../../secrets/x.png"}) |> response(404)
    assert build_conn() |> get("/files/raw", %{"path" => "logs/audit.jsonl"}) |> response(404)
  end
```

(`write_tmp_png!/0`: write a few valid PNG magic bytes + payload to a tmp file, return the path.)

- [ ] **Step 2: Run** — FAIL (404 routes).
- [ ] **Step 3: Implement** router pipeline + scope (ABOVE the SPA catch-all):

```elixir
  pipeline :files_upload do
    plug :accepts, ["json"]
    plug ValeaWeb.Plugs.ControlToken
  end

  scope "/files", ValeaWeb do
    pipe_through :files_upload
    post "/upload", FilesController, :upload
  end

  scope "/files", ValeaWeb do
    pipe_through :api
    get "/raw", FilesController, :raw
  end
```

Controller with the exact validations above; containment helper shared for both actions (attribute mount → enabled → lexical prefix + `resolve_real` under mount root). Endpoint parsers gain `length: 12_000_000`.

- [ ] **Step 4: Run** — PASS; full `mix test`.
- [ ] **Step 5: Commit** — `git commit -m "feat(backend): contained image upload/serve endpoints"`

---

### Task C7: FE — image extension, paste/drag upload, relative-src rendering

**Files:**
- Modify: `frontend/package.json` (`bun add @tiptap/extension-image@^2.27.2`), `frontend/src/lib/components/editor/PageEditor.svelte` (extension + editorProps handlers, `pagePath` prop)
- Create: `frontend/src/lib/editor/image-upload.ts`, `image-upload.test.ts`
- Modify: `frontend/src/lib/api/client.ts` (`uploadImage(file, pagePath)` via `fetch('/files/upload', ...)` with the same token header helper the HTTP RPC fallback uses)
- Test: `image-upload.test.ts`

**Interfaces:**
- Produces (pure, tested):

```ts
// image-upload.ts
export function isAllowedImage(file: File): boolean;              // type/extension allowlist
export function resolveImageSrc(src: string, pagePath: string): string;
// relative src → resolved workspace-vocab path → `/files/raw?path=<encoded>`;
// absolute src (external mounts) → same endpoint; http(s)/data: srcs returned unchanged.
export function joinRelative(pageDir: string, rel: string): string; // lexical ../ resolution
```

- On-disk truth: the image NODE's `src` attr stores the `rel_from_page` value from the upload response (or the absolute path for external-mount pages) — that's what serializes into markdown. Rendering maps it through `resolveImageSrc` via the extension's `renderHTML`.

- [ ] **Step 1: Failing tests** for `joinRelative` (`joinRelative('mounts/m/Clients', '../Assets/x.png') === 'mounts/m/Assets/x.png'`; absolute page dirs too), `resolveImageSrc` (relative → `/files/raw?path=mounts%2Fm%2FAssets%2Fx.png`; `https://...` unchanged), `isAllowedImage`.
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** the module; extend `PageEditor.svelte`:
  - new prop `pagePath: string` (the route passes its page path);
  - extensions gain `Image.extend({ renderHTML({ HTMLAttributes }) { return ['img', { ...HTMLAttributes, src: resolveImageSrc(String(HTMLAttributes.src ?? ''), pagePath) }]; } })` (attrs keep the raw src; only the DOM output is mapped);
  - `editorProps: { handlePaste, handleDrop }` — extract image files from the clipboard/drop, for each allowed file call `api.uploadImage(file, pagePath)`, insert `{ type: 'image', attrs: { src: data.relFromPage, alt: file.name } }` at the drop/caret position; non-image files fall through (default handling); upload failure → quiet inline editor notification via the existing error pattern (set a store error the route renders — reuse the save-error surface).
  - `client.ts`: `uploadImage` posts `FormData` (`file`, `page_path`) with the `x-valea-token` header, returns `ApiResult<{ path: string; relFromPage: string }>` (map snake_case response keys).
- [ ] **Step 4: Run** `bun run test && bun run check` — PASS. **Step 5: Commit** — `git commit -m "feat(frontend): image paste/drag upload with relative on-disk srcs"`

---

### Task C8: FE — page-link picker (`[[` and `@`) with create-on-empty

**Files:**
- Create: `frontend/src/lib/editor/page-link.ts`, `page-link.test.ts`, `frontend/src/lib/editor/vendor/page_link_suggestion.js` (renderer, mirroring `slash_command.js`'s tippy menu)
- Modify: `frontend/src/lib/components/editor/PageEditor.svelte` (register two Suggestion-based extensions)
- Test: `page-link.test.ts`

**Interfaces:**
- Consumes: C2 `api.icmSearch(query)`; `@tiptap/suggestion` (installed); C7's `joinRelative`; `workspaceStore` (no workspace-absolute path needed — see rule below).
- Produces (pure, tested):

```ts
// page-link.ts
export function linkDestination(sourcePath: string, targetPath: string): string;
// both workspace-relative → relative path from source's dir (../ math, lexical);
// either absolute → targetPath verbatim when absolute, else: if source is absolute
// and target workspace-relative, return target verbatim (workspace-relative form —
// the one addressable vocabulary the FE has; backend resolution treats it correctly
// only for same-workspace readers, which is exactly the non-portable cross-boundary
// case the spec accepts).
export function pickerItems(results: SearchResult[], query: string): PickerItem[];
// maps search results to menu items; appends a { kind: 'create', title: `Create "<query>"` }
// item when query is non-empty and no exact-title match exists.
```

- Command behavior: selecting a page item deletes the trigger range and inserts the target's title text wrapped in a link mark `{ href: linkDestination(pagePath, item.path) }`; the create item calls `api.createIcmPage(parentOf(pagePath), query)` then inserts the link to the new page.
- Two extension instances share one factory: `createPageLinkSuggestion({ char: '[[' })` and `{ char: '@' }` (default `allowedPrefixes` keeps `mara@example` from triggering).

- [ ] **Step 1: Failing tests** for `linkDestination` (same-dir sibling → `Sibling.md`; cross-folder → `../Offers/X.md`; embedded→embedded cross-mount → `../../second/C.md`; absolute target → verbatim; spaces preserved — wrapping is the converter's job) and `pickerItems` (create item appears/omits).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** `page-link.ts`; write `page_link_suggestion.js` closely following `slash_command.js`'s structure (Suggestion plugin config: `char`, `items: async ({ query }) => ...` calling the injected search, `render` with the same tippy menu class, `command`); register in `PageEditor.svelte` with the page's `pagePath` and `api` injected. Debounce the search call 150 ms inside `items`.
- [ ] **Step 4: Run** `bun run test && bun run check` — PASS. **Step 5: Commit** — `git commit -m "feat(frontend): [[ and @ page-link picker with create-on-empty"`

---

### Task C9: FE — Cmd+K palette, MRU, link-click navigation, dangling links

**Files:**
- Create: `frontend/src/lib/components/palette/SearchPalette.svelte`, `frontend/src/lib/components/palette/palette.ts`, `palette.test.ts`, `frontend/src/lib/stores/recent-pages.ts`, `recent-pages.test.ts`, `frontend/src/lib/editor/link-nav.ts`, `link-nav.test.ts`
- Modify: `frontend/src/routes/+layout.svelte` (global keydown + palette mount), `frontend/src/routes/knowledge/[...path]/+page.svelte` (record MRU; pass dangling set), `frontend/src/lib/components/editor/PageEditor.svelte` (link click handling + dangling decoration), `frontend/src/routes/layout.css` or `tiptap.css` (`.link-dangling` style)

**Interfaces:**
- Consumes: C2 `api.icmSearch`, `api.icmPathsExist`; C7 `joinRelative`; `encodePath` from `$lib/shell/nav`.
- Produces (pure, tested):
  - `palette.ts`: `paletteReduce(state, event)` state machine — `{ open, query, results, skippedNote, active }`; events `open/close/input(results)/arrow(up|down)/enter` → `{ goto?: string }`. Empty query → `results` from MRU.
  - `recent-pages.ts`: `recordVisit(path)`, `recentPages(): string[]` — max 10, most-recent-first, deduped, persisted `localStorage['valea.recent-pages']` (guard `typeof localStorage`).
  - `link-nav.ts`: `classifyHref(href, pagePath): { kind: 'page'; path: string } | { kind: 'external'; url: string } | { kind: 'file' }` — `.md` (relative resolved via `joinRelative`, or absolute) → page; `http(s)` → external; else file. `collectDocLinkPaths(docJson, pagePath): string[]` — walks the ProseMirror JSON for link marks + image nodes, resolves page-kind hrefs (used for the dangling check).
- Behavior: `window` keydown `cmd+k`/`ctrl+k` toggles the palette (skip when focus is in an input/textarea/contenteditable EXCEPT the editor — the palette opens over it); Enter navigates to `/knowledge/<encodePath(path)>`. Editor `handleClickOn` for link marks: page → `goto`; external → `window.open(url, '_blank')`; file → no-op. Dangling: on page load and after each save flush, `collectDocLinkPaths` → `api.icmPathsExist` → missing set → a ProseMirror decoration plugin adds class `link-dangling` (dashed `text-warn-ink` underline) to link marks whose resolved path is missing; clicking a dangling link opens a small confirm dialog "Create this page?" → `api.createIcmPage(parentDir, name)` → `goto` the new page.

- [ ] **Step 1: Failing tests** for `paletteReduce`, `recent-pages`, `classifyHref`, `collectDocLinkPaths` (fixtures: doc JSON with a relative link, an absolute link, an http link, an image).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** modules, then the Svelte wiring (palette dialog styled like existing dialogs: input + results list, mount badge + snippet per row, skipped-mounts notice line when present).
- [ ] **Step 4: Run** `bun run test && bun run check` — PASS. **Step 5: Commit** — `git commit -m "feat(frontend): cmd+k search palette, link navigation, dangling-link create"`

---

### Task C10: FE — backlinks panel, impact dialogs, template select

**Files:**
- Create: `frontend/src/lib/components/knowledge/BacklinksPanel.svelte`, `backlinks-panel.ts`, `backlinks-panel.test.ts`, `frontend/src/lib/components/knowledge/template-options.ts`, `template-options.test.ts`
- Modify: `frontend/src/routes/knowledge/[...path]/+page.svelte` (panel below the editor), `RenameDialog.svelte` + `DeleteDialog.svelte` (page counts — extract/extend the impact-line helper), `NewEntryDialog.svelte` (template select)

**Interfaces:**
- Consumes: C3's references RPC `{workflows, pages}`; C5 `api.createIcmPageFromTemplate`; `icmStore.groups` (`MountGroup = {mount, title, rootRel, tree: IcmNode[]}`).
- Produces (pure, tested):
  - `backlinks-panel.ts`: `groupReferences(refs): { pages: PageRef[]; workflows: WfRef[]; empty: boolean }` and `impactLine(pageCount, workflowCount): string | null` — `"Also updates 2 pages and 1 workflow that read this page."` / singulars / null when both zero.
  - `template-options.ts`: `templateOptions(groups, parentPath): { label: string; path: string }[]` — finds the mount group containing `parentPath` (prefix match on `rootRel`), returns its `Templates/` folder's page children (empty when none).
- Behavior: BacklinksPanel fetches on path change, renders "Referenced by" with two groups (page rows link via `encodePath`; workflow rows show the workflow name), hidden when empty. Rename/Delete dialogs call the same references RPC (already do) and render the new `impactLine`; Delete lists both kinds. NewEntryDialog (page mode): a `<select>` "Start from" defaulting to "Empty page", options from `templateOptions`; submit branches to `createIcmPageFromTemplate` when a template is chosen.

- [ ] **Step 1: Failing tests** for `groupReferences`, `impactLine` (0/1/n matrix), `templateOptions` (mount with and without Templates/).
- [ ] **Step 2: Run** — FAIL. **Step 3: Implement** + wire.
- [ ] **Step 4: Run** `bun run test && bun run check` — PASS. **Step 5: Commit** — `git commit -m "feat(frontend): backlinks panel, page-aware impact dialogs, template select"`

---

### Task C11: Docs + acceptance sweep

**Files:**
- Modify: `docs/ARCHITECTURE.md` (search/backlinks scan posture + FTS5 seam note, link conventions, rename link-rewrite, templates, Assets + /files endpoints incl. the GET token-exemption rationale, palette), `docs/VISION.md` (roadmap item 9 "Knowledge & editor depth (Spec C)")

- [ ] **Step 1:** Write both doc updates, claim-checked (every named module/function greps to real code).
- [ ] **Step 2:** Full gates: `cd backend && mix format --check-formatted && mix test`; `just codegen` + `git diff --exit-code frontend/src/lib/api/`; `cd frontend && bun run check && bun run test`. All green.
- [ ] **Step 3: Commit** — `git commit -m "docs: knowledge-depth as-built architecture + roadmap"`

---

## Plan self-review notes (retained for the executor)

- Spec coverage: §Posture (scan, budgets, seam) → C1/C2. §1 Search → C1/C2/C9. §2 Links → C4 (serialization) + C8 (picker) + C9 (click nav, dangling). §3 Backlinks → C3 + C10. §4 Rename integrity → C4. §5 Templates → C5 + C10. §6 Images → C6 + C7. Error table rows map: slow mount → C1 test; dangling → C9; rewrite-vs-open-editor → existing conflict banner (C4 changes disk → watcher-driven external-change path already handles it — verify manually in acceptance); unparseable page in impact scan → C3 (`destinations/3` returns [] on parse failure — file simply reports no links; the dialog's "could not check" copy is covered by the folder-fallback line that already exists); template placeholders → C5; upload caps/types → C6; picker zero results → C8.
- Type consistency: `Backlinks.destinations/3` (C3) consumed by C4; `Valea.Paths.relative/2` (C4) consumed by C6/C7-mirror; `joinRelative` (C7) consumed by C8/C9; references RPC shape (C3) consumed by C10; `icmSearch` result `terms` (C1) consumed by palette highlighting (C9 renders bold via text splitting, no `{@html}`).
- Deliberate scope note: `rel_from_page` for an EXTERNAL-mount page is computed with the same `Valea.Paths.relative/2` over absolute paths — both page and Assets live under the same mount root, so the relative form is always intra-mount and portable.
