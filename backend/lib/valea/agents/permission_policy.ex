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
  # Default reference roots; ctx[:read_roots] overrides — a LIST so ICM
  # mounts can extend it later (spec §Composition-ready choices).
  @default_read_roots ["icm", "sources", "prompts"]
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

  defp denied?({:ok, path}, ws) do
    rel = Path.relative_to(path, ws)
    top = rel |> Path.split() |> List.first()
    top in @protected_dirs or String.starts_with?(Path.basename(rel), @db_prefix)
  end

  defp all_in_read_roots?(resolved, ws, read_roots) do
    Enum.all?(resolved, fn {:ok, path} ->
      rel = Path.relative_to(path, ws)
      top = rel |> Path.split() |> List.first()
      top in read_roots or rel in @root_files
    end)
  end

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
