defmodule Valea.Agents.PermissionPolicy do
  @moduledoc """
  deny -> allow -> ask, unclassifiable = ask (spec §PermissionPolicy).

  Pure: decisions depend only on the permission item and the ctx. Every
  decision is audited by the `SessionServer`, not here.

  All path reasoning goes through `Valea.Paths.resolve_real/2` so a symlink
  inside the workspace can never smuggle a read/write outside it. The
  workspace base and the workflow write targets are ALSO symlink-resolved
  before comparison — otherwise `/var` vs `/private/var` (macOS) and any
  other symlinked ancestor would defeat the containment and exact-match
  checks.
  """

  @protected_dirs ["secrets", "logs", ".claude", ".git"]
  @db_prefix "app.sqlite"
  @read_kinds ["read"]
  @write_kinds ["edit", "write", "delete", "move"]
  # Fallback when a caller starts a session without computing read_roots
  # (e.g. a bare PermissionPolicy.decide/2 call in a test). The real value
  # every live session gets is computed at session start
  # (`SessionServer.init/1`): `["sources"] ++ Enum.map(Mounts.enabled(ws), &
  # &1.rel_root)`, so each mount's `mounts/<name>` is a read root ONLY while
  # that mount is enabled — a disabled/absent mount is simply not in the
  # list, so its reads fall through to `:ask` (never a hard deny; deny is
  # reserved for the protected dirs above). `icm` and `prompts` are gone
  # from the default: `icm/` no longer exists (mounts replaced it) and
  # `prompts/` now lives inside each mount, covered by that mount's own
  # `mounts/<name>` root.
  @default_read_roots ["sources"]
  @root_files ["AGENTS.md", "CLAUDE.md"]

  @spec decide(map(), map()) :: :ask | {:allow, String.t()} | {:deny, String.t()}
  def decide(item, ctx) do
    kind = item["kind"]
    read_roots = ctx[:read_roots] || @default_read_roots
    ws = base_real(ctx.workspace)
    paths = extract_paths(item)
    resolved = Enum.map(paths, &Valea.Paths.resolve_real(&1, ctx.workspace))

    cond do
      Enum.any?(resolved, &denied?(&1, ws)) ->
        {:deny, "reject_once"}

      paths == [] ->
        :ask

      Enum.any?(resolved, &(elem(&1, 0) == :error)) ->
        :ask

      kind in @read_kinds and all_in_read_roots?(resolved, ws, read_roots) ->
        {:allow, "allow_once"}

      kind in @write_kinds and ctx.session_kind == "workflow" and
          all_in_write_paths?(resolved, ctx.write_paths, ctx.workspace) ->
        {:allow, "allow_once"}

      true ->
        :ask
    end
  end

  defp base_real(workspace) do
    case Valea.Paths.resolve_real(workspace, workspace) do
      {:ok, real} -> real
      _ -> workspace
    end
  end

  defp extract_paths(item) do
    raw = item["rawInput"] || %{}

    ["file_path", "path", "notebook_path", "filePath"]
    |> Enum.map(&raw[&1])
    |> Enum.filter(&is_binary/1)
  end

  defp denied?({:error, :outside}, _ws), do: true
  defp denied?({:error, _}, _ws), do: false

  # Case-INSENSITIVE match: on a case-insensitive filesystem (macOS APFS
  # default) `SECRETS/x` and `Secrets/x` resolve to the same protected dir as
  # `secrets/x`, so the hard-deny must not be defeated by casing. The
  # `@protected_dirs` / `@db_prefix` references are already lowercase.
  defp denied?({:ok, path}, ws) do
    rel = Path.relative_to(path, ws)
    top = rel |> Path.split() |> List.first()

    (is_binary(top) and String.downcase(top) in @protected_dirs) or
      String.starts_with?(String.downcase(Path.basename(rel)), @db_prefix)
  end

  # A read root may be multi-segment (`mounts/a`), so membership is checked
  # by leading PATH COMPONENTS, not a top-segment string or a lexical
  # `String.starts_with?/2` — the latter would let `mounts/a` wrongly match
  # `mounts/ab/...` (a component boundary, not a character boundary).
  defp all_in_read_roots?(resolved, ws, read_roots) do
    roots = Enum.map(read_roots, &Path.split/1)

    Enum.all?(resolved, fn {:ok, path} ->
      rel = Path.relative_to(path, ws)
      parts = Path.split(rel)
      Enum.any?(roots, &under_root?(&1, parts)) or rel in @root_files
    end)
  end

  defp under_root?(root_parts, parts), do: Enum.take(parts, length(root_parts)) == root_parts

  defp all_in_write_paths?(resolved, write_paths, workspace) do
    allowed =
      write_paths
      |> Enum.map(&Valea.Paths.resolve_real(&1, workspace))
      |> Enum.flat_map(fn
        {:ok, p} -> [p]
        _ -> []
      end)

    Enum.all?(resolved, fn {:ok, path} -> path in allowed end)
  end
end
