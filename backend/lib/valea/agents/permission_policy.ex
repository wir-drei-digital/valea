defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  deny -> allow -> ask, unclassifiable = ask (spec §PermissionPolicy).

  Pure: decisions depend only on the permission item and the ctx. Every
  decision is audited by the `SessionServer`, not here.

  All path reasoning goes through `Valea.Paths.resolve_real/2` so a symlink
  can never smuggle a read/write outside a recognized root. Every ctx-supplied
  base/root is ALSO symlink-resolved before comparison — otherwise `/var` vs
  `/private/var` (macOS) and any other symlinked ancestor would defeat
  containment and exact-match checks.

  ## Two ctx shapes, one entry point (Task 5.3 in-flight migration)

  `decide/2` dispatches on the SHAPE of `ctx`:

    * a ctx carrying `:workspace_root` uses the NEW split contract
      (`decide_split/2`, below) — `workspace_root` (absolute; protects
      operational state), `cwd` (absolute primary ICM root; base for
      *relative* candidate paths), `read_roots` (absolute list: primary root
      + related roots + exact task inputs), `session_kind`, `write_paths`
      (absolute), `write_roots` (absolute).
    * a ctx WITHOUT `:workspace_root` (only `:workspace`) uses the LEGACY
      contract (`decide_legacy/2`, below) — unchanged from before Task 5.3.
      `SessionServer.init/1` and `Valea.Workflows.Runner` still build this
      shape (`ctx.workspace`, ws-relative `ctx.read_roots`,
      `ctx.extra_roots`) as of this task; they migrate to the split contract
      in Tasks 5.4/5.5. Once every caller passes `workspace_root`/`cwd`, the
      legacy branch and its helpers can be deleted outright.

  Both branches share the same non-negotiable invariants: every path decision
  goes through `Valea.Paths.resolve_real/2`, membership is segment-boundary
  (never a lexical string-prefix — `mounts/a` must not match `mounts/ab/...`),
  and deny always wins over allow; an unclassifiable candidate is `:ask`,
  never a silent allow.

  ## Split contract decision order (deny -> allow -> ask)

    1. **Deny** if any resolved candidate is inside a protected workspace dir
       (`<workspace_root>/{logs,config,secrets,runtime,.git}` or
       `<workspace_root>/app.sqlite*`), or the tool is `WebFetch`/`WebSearch`.
    2. **Deny** (symlink escape) if any candidate resolves OUTSIDE every
       recognized area — `workspace_root` itself, every `read_root`, and
       every write grant (`write_paths`/`write_roots`). A relative candidate
       that lexically escapes `cwd` (`resolve_real`'s own `{:error,
       :outside}`) counts as escaping too, since relative candidates only
       ever resolve against `cwd`. Landing INSIDE `workspace_root` without
       being in a granted root is NOT an escape — it just isn't granted yet,
       so it falls through to `:ask` (step 5) rather than being denied; only
       territory outside the whole recognized universe is treated as a
       symlink-escape-style deny.
    3. **Allow read** if `kind` is a read kind and EVERY candidate resolves
       inside some `read_root` (or is a root instruction file — see below).
    4. **Allow write** if `kind` is a write kind, `session_kind == "workflow"`,
       and every candidate is in `write_paths` or under a `write_root`.
    5. Else **ask**.

  Relative candidates resolve against `cwd` (never `workspace_root`) — this
  is the behavioral heart of the split. `read_roots`/`write_paths`/
  `write_roots` are absolute, so membership is segment-boundary: `resolved ==
  root or starts_with?(resolved <> "/", root <> "/")`.

  `@root_files` (`AGENTS.md`/`CLAUDE.md`, always-allowed relative reads) now
  resolve against `cwd` (the ICM root that actually carries those files),
  never `workspace_root` — kept as an explicit bypass (on top of ordinary
  `read_roots` membership, which already covers it whenever `cwd` is itself a
  read root, per the contract) so a root instruction file stays readable even
  if a caller's `read_roots` construction ever omits `cwd` itself.
  """

  @read_kinds ["read"]
  @write_kinds ["edit", "write", "delete", "move"]

  ## ===========================================================================
  ## Split contract (Task 5.3): workspace_root / cwd / read_roots (absolute)
  ## ===========================================================================

  @protected_dirs ~w(logs config secrets runtime .git)
  @db_prefix "app.sqlite"
  @root_files ["AGENTS.md", "CLAUDE.md"]
  @denied_tools ["WebFetch", "WebSearch"]

  @spec decide(map(), map()) :: :ask | {:allow, String.t()} | {:deny, String.t()}
  def decide(item, ctx) do
    if Map.has_key?(ctx, :workspace_root) do
      decide_split(item, ctx)
    else
      decide_legacy(item, ctx)
    end
  end

  defp decide_split(item, ctx) do
    kind = item["kind"]
    tool = item["toolName"]

    workspace_root = split_real(ctx.workspace_root)
    cwd = split_real(ctx.cwd)
    read_roots = Enum.map(ctx[:read_roots] || [], &split_real/1)
    write_paths = Enum.map(ctx[:write_paths] || [], &split_real/1)
    write_roots = Enum.map(ctx[:write_roots] || [], &split_real/1)

    paths = extract_paths(item)
    resolved = Enum.map(paths, &split_resolve_candidate(&1, cwd))

    cond do
      tool in @denied_tools ->
        {:deny, "reject_once"}

      Enum.any?(resolved, &split_protected?(&1, workspace_root)) ->
        {:deny, "reject_once"}

      Enum.any?(
        resolved,
        &split_escaped?(&1, workspace_root, read_roots, write_paths, write_roots)
      ) ->
        {:deny, "reject_once"}

      paths == [] ->
        :ask

      Enum.any?(resolved, &(elem(&1, 0) == :error)) ->
        :ask

      kind in @read_kinds and split_all_read?(resolved, cwd, read_roots) ->
        {:allow, "allow_once"}

      kind in @write_kinds and ctx.session_kind == "workflow" and
          split_all_write?(resolved, write_paths, write_roots) ->
        {:allow, "allow_once"}

      true ->
        :ask
    end
  end

  # Self-base realpath resolution: every absolute ctx-supplied base/root
  # (`workspace_root`, `cwd`, each `read_roots`/`write_paths`/`write_roots`
  # member) is walked through `resolve_real/2` against ITSELF before use, so
  # a symlinked ancestor (macOS `/var` -> `/private/var`, historically `/tmp`
  # -> `/private/tmp`) can't desync a ctx-supplied root from the fully
  # symlink-chased candidate paths it's compared against. Falls back to the
  # input unresolved if the path doesn't exist yet or can't be walked (a
  # `write_paths` target commonly doesn't exist until the agent creates it).
  defp split_real(path) do
    case Valea.Paths.resolve_real(path, path) do
      {:ok, real} -> real
      _ -> path
    end
  end

  # Absolute candidates (every related-root/exact-input read arrives this
  # way) are resolved against THEMSELVES — a fixed `cwd` base would reject
  # every legitimately-absolute result as `{:error, :outside}` before
  # `read_roots` membership could ever be checked, since `read_roots` is no
  # longer required to be an ancestor of `cwd`. Relative candidates are the
  # one case that resolves against `cwd` — the behavioral heart of the split.
  defp split_resolve_candidate(path, cwd) do
    if String.starts_with?(path, "/") do
      Valea.Paths.resolve_real(path, path)
    else
      Valea.Paths.resolve_real(path, cwd)
    end
  end

  # Case-INSENSITIVE match: on a case-insensitive filesystem (macOS APFS
  # default) `SECRETS/x` and `Secrets/x` resolve to the same protected dir as
  # `secrets/x`, so the hard-deny must not be defeated by casing.
  #
  # Scoped to `workspace_root`: this check only ever hard-denies
  # `<workspace_root>/{logs,config,secrets,runtime,.git}` and
  # `<workspace_root>/app.sqlite*` (spec §PermissionPolicy step 1). A
  # resolved candidate that is NOT under `workspace_root` at all — e.g. a
  # file in a granted `read_root` that happens to be named `app.sqlite.md`,
  # or an exact task input outside the workspace — must not be swept into
  # this deny just because `Path.basename/1` matches the db prefix; that
  # would over-deny territory the spec never asked this check to cover.
  # `Path.relative_to/2` on a path outside `workspace_root` returns it
  # unchanged, so the basename/top-segment tests below are only meaningful
  # once containment is confirmed first.
  defp split_protected?({:error, _}, _workspace_root), do: false

  defp split_protected?({:ok, resolved}, workspace_root) do
    split_under_root?(resolved, workspace_root) and
      protected_relative?(resolved, workspace_root, @protected_dirs, @db_prefix)
  end

  # A relative candidate that lexically escapes `cwd` (the only base relative
  # candidates ever resolve against) can't be checked against any OTHER root
  # — `resolve_real/2` doesn't hand back a resolved path on `{:error,
  # :outside}` — so it's treated the same as any other candidate landing
  # outside the whole recognized universe: a deny, never a silent `:ask`
  # widen. `{:error, :invalid}` (32-hop symlink budget exhausted) is left for
  # the `:ask` fallback in `decide_split/2`, same as an ordinary resolve
  # failure.
  defp split_escaped?(
         {:error, :outside},
         _workspace_root,
         _read_roots,
         _write_paths,
         _write_roots
       ),
       do: true

  defp split_escaped?({:error, _}, _workspace_root, _read_roots, _write_paths, _write_roots),
    do: false

  defp split_escaped?({:ok, resolved}, workspace_root, read_roots, write_paths, write_roots) do
    not (split_under_root?(resolved, workspace_root) or
           split_root_member?(resolved, read_roots) or
           resolved in write_paths or
           split_root_member?(resolved, write_roots))
  end

  defp split_all_read?(resolved, cwd, read_roots) do
    Enum.all?(resolved, fn
      {:ok, path} -> split_root_member?(path, read_roots) or split_root_file?(path, cwd)
      _ -> false
    end)
  end

  defp split_root_file?(resolved, cwd) do
    split_under_root?(resolved, cwd) and Path.relative_to(resolved, cwd) in @root_files
  end

  defp split_all_write?(resolved, write_paths, write_roots) do
    Enum.all?(resolved, fn
      {:ok, path} -> path in write_paths or split_root_member?(path, write_roots)
      _ -> false
    end)
  end

  # Root-SET membership by leading PATH COMPONENTS — never a lexical
  # `String.starts_with?/2`, which would let `mounts/a` wrongly match
  # `mounts/ab/...` (a component boundary, not a character boundary).
  defp split_root_member?(path, roots), do: Enum.any?(roots, &split_under_root?(path, &1))

  defp split_under_root?(path, root),
    do: path == root or String.starts_with?(path <> "/", root <> "/")

  ## ===========================================================================
  ## Legacy contract (pre-Task-5.3): ctx.workspace, ws-relative read_roots,
  ## extra_roots. Kept verbatim for `SessionServer`/`Valea.Workflows.Runner`
  ## until they migrate to the split contract (Tasks 5.4/5.5) — DELETE this
  ## whole section (and its dedicated test module) once every caller passes
  ## `workspace_root`/`cwd`.
  ## ===========================================================================

  @legacy_protected_dirs ["secrets", "logs", ".claude", ".git"]
  @legacy_db_prefix "app.sqlite"
  @legacy_default_read_roots ["sources"]
  @legacy_root_files ["AGENTS.md", "CLAUDE.md"]

  defp decide_legacy(item, ctx) do
    kind = item["kind"]
    read_roots = ctx[:read_roots] || @legacy_default_read_roots
    # Fallback `[]` mirrors `read_roots`' own bare-call fallback above: a
    # caller (or test) that starts a session/calls `decide/2` directly
    # without computing extra_roots simply gets no external read surface,
    # never a crash.
    extra_roots = ctx[:extra_roots] || []
    ws = legacy_base_real(ctx.workspace)
    paths = extract_paths(item)
    resolved = Enum.map(paths, &legacy_resolve_candidate(&1, ctx.workspace))
    pairs = Enum.zip(paths, resolved)

    cond do
      Enum.any?(resolved, &legacy_denied?(&1, ws)) ->
        {:deny, "reject_once"}

      Enum.any?(pairs, fn {raw, r} ->
        legacy_escaped_root?(raw, r, ctx.workspace, ws, read_roots, extra_roots)
      end) ->
        {:deny, "reject_once"}

      paths == [] ->
        :ask

      Enum.any?(resolved, &(elem(&1, 0) == :error)) ->
        :ask

      kind in @read_kinds and legacy_all_in_read_roots?(resolved, ws, read_roots, extra_roots) ->
        {:allow, "allow_once"}

      kind in @write_kinds and ctx.session_kind == "workflow" and
          (legacy_all_in_write_paths?(resolved, ctx.write_paths, ctx.workspace) or
             legacy_all_in_write_roots?(resolved, ctx[:write_roots] || [], ctx.workspace)) ->
        {:allow, "allow_once"}

      true ->
        :ask
    end
  end

  defp legacy_resolve_candidate(path, workspace) do
    if String.starts_with?(path, "/") do
      Valea.Paths.resolve_real(path, path)
    else
      Valea.Paths.resolve_real(path, workspace)
    end
  end

  defp legacy_escaped_root?(raw, {:ok, resolved}, workspace, ws, read_roots, extra_roots) do
    legacy_root_membership?(raw, workspace, read_roots, extra_roots) and
      not legacy_root_membership?(resolved, ws, read_roots, extra_roots)
  end

  defp legacy_escaped_root?(_raw, _resolved, _workspace, _ws, _read_roots, _extra_roots),
    do: false

  defp legacy_base_real(workspace) do
    case Valea.Paths.resolve_real(workspace, workspace) do
      {:ok, real} -> real
      _ -> workspace
    end
  end

  defp legacy_denied?({:error, :outside}, _ws), do: true
  defp legacy_denied?({:error, _}, _ws), do: false

  # Scoped to `ws` (the legacy workspace base), mirroring `split_protected?`
  # above: this must only hard-deny `<ws>/{secrets,logs,.claude,.git}` and
  # `<ws>/app.sqlite*`, never a same-named file living outside `ws` entirely
  # (e.g. reached via `extra_roots`). `legacy_under_lexical?/2` is the same
  # segment-boundary containment test `legacy_escaped_root?/6` already uses
  # elsewhere in this module.
  defp legacy_denied?({:ok, path}, ws) do
    legacy_under_lexical?(path, ws) and
      protected_relative?(path, ws, @legacy_protected_dirs, @legacy_db_prefix)
  end

  defp legacy_all_in_read_roots?(resolved, ws, read_roots, extra_roots) do
    Enum.all?(resolved, fn {:ok, path} ->
      legacy_root_membership?(path, ws, read_roots, extra_roots)
    end)
  end

  defp legacy_root_membership?(path, ws_base, read_roots, extra_roots) do
    cond do
      not String.starts_with?(path, "/") ->
        legacy_matches_any_root?(read_roots, path) or path in @legacy_root_files

      legacy_under_lexical?(path, ws_base) ->
        rel = Path.relative_to(path, ws_base)
        legacy_matches_any_root?(read_roots, rel) or rel in @legacy_root_files

      true ->
        legacy_matches_any_root?(extra_roots, path)
    end
  end

  defp legacy_matches_any_root?(roots, candidate_rel) do
    parts = Path.split(candidate_rel)
    Enum.any?(roots, &legacy_under_root?(Path.split(&1), parts))
  end

  defp legacy_under_root?(root_parts, parts),
    do: Enum.take(parts, length(root_parts)) == root_parts

  defp legacy_under_lexical?(path, base),
    do: path == base or String.starts_with?(path <> "/", base <> "/")

  defp legacy_all_in_write_paths?(resolved, write_paths, workspace) do
    allowed =
      write_paths
      |> Enum.map(&Valea.Paths.resolve_real(&1, workspace))
      |> Enum.flat_map(fn
        {:ok, p} -> [p]
        _ -> []
      end)

    Enum.all?(resolved, fn {:ok, path} -> path in allowed end)
  end

  defp legacy_all_in_write_roots?(_resolved, [], _workspace), do: false

  defp legacy_all_in_write_roots?(resolved, roots, workspace) do
    allowed =
      for root <- roots,
          {:ok, real} <- [Valea.Paths.resolve_real(root, workspace)],
          do: real

    allowed != [] and
      Enum.all?(resolved, fn
        {:ok, p} -> Enum.any?(allowed, &(p == &1 or String.starts_with?(p, &1 <> "/")))
        _ -> false
      end)
  end

  ## ===========================================================================
  ## Shared
  ## ===========================================================================

  # Protected-dir / db-prefix test against an ALREADY-CONFIRMED-contained
  # `path` (callers must check containment under `root` first — see
  # `split_protected?/2` and `legacy_denied?/2` above). Both the split and
  # legacy protected checks share this shape: a hard-deny if the resolved
  # path's top segment (relative to `root`) is a protected dir name, or its
  # basename starts with the db prefix — both compared case-insensitively.
  defp protected_relative?(path, root, protected_dirs, db_prefix) do
    rel = Path.relative_to(path, root)
    top = rel |> Path.split() |> List.first()

    (is_binary(top) and String.downcase(top) in protected_dirs) or
      String.starts_with?(String.downcase(Path.basename(rel)), db_prefix)
  end

  defp extract_paths(item) do
    raw = item["rawInput"] || %{}

    ["file_path", "path", "notebook_path", "filePath"]
    |> Enum.map(&raw[&1])
    |> Enum.filter(&is_binary/1)
  end
end
