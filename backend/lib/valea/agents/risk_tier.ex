defmodule Valea.Agents.RiskTier do
  @moduledoc """
  Server-derived risk tier for a path that lives inside a mount: "high"
  for behavior-bearing files (the mount's instruction spine and its
  workflow contracts — an approved edit changes future agent behavior),
  "medium" for everything else inside a mount, nil for paths that do not
  attribute to any mount (the workspace shell, or nowhere). The tier is
  display + envelope metadata, never an access decision.
  """

  alias Valea.Mounts

  @behavior_files ["AGENTS.md", "CLAUDE.md", "icm.yaml"]

  @spec classify(String.t(), String.t() | nil) :: String.t() | nil
  def classify(workspace, path) when is_binary(path) do
    path = normalize(workspace, path)

    case Mounts.mount_for(workspace, path) do
      nil -> nil
      mount -> tier(inner_path(mount, path))
    end
  end

  def classify(_workspace, _path), do: nil

  # An absolute path under the workspace is the same content addressed
  # physically — attribute it as its workspace-relative form. Absolute
  # paths elsewhere stay absolute (external-mount vocabulary).
  defp normalize(workspace, "/" <> _ = abs) do
    case Path.relative_to(abs, workspace) do
      ^abs -> abs
      rel -> rel
    end
  end

  defp normalize(_workspace, rel), do: rel

  defp inner_path(%{rel_root: rel}, path) when is_binary(rel),
    do: String.replace_prefix(path, rel <> "/", "")

  defp inner_path(%{root: root}, path),
    do: String.replace_prefix(path, root <> "/", "")

  defp tier(inner) do
    if inner in @behavior_files or String.starts_with?(inner, "Workflows/") do
      "high"
    else
      "medium"
    end
  end
end
