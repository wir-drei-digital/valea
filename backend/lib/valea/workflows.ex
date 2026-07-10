defmodule Valea.Workflows do
  @moduledoc """
  Reads workflow contracts from `icm/Workflows/*.md` — parsed frontmatter
  (trigger, sources, risk_level, approval) plus a body-derived preview (H1
  name, first paragraph description, numbered `## Process` steps). The
  filesystem is the source of truth; a `Workflows/` page with no frontmatter
  is not a contract (skipped by `list/0`, `{:error, :not_found}` from
  `get/1`). `Valea.Workflows.Runner` executes a workflow this module
  describes.
  """

  alias Valea.Workspace.Manager

  @dir "icm/Workflows"

  @doc "All workflow contracts under icm/Workflows/, `{:ok, []}` when no workspace is open."
  @spec list() :: {:ok, [map()]}
  def list do
    case Manager.current() do
      {:ok, %{path: workspace}} ->
        {:ok,
         workspace
         |> workflow_files()
         |> Enum.map(&parse(&1, workspace))
         |> Enum.reject(&is_nil/1)
         |> Enum.sort_by(& &1.path)}

      {:error, :no_workspace} ->
        {:ok, []}
    end
  end

  @doc """
  One workflow contract by its workspace-relative path (as returned in
  `list/0`'s `path` field, e.g. `"icm/Workflows/New Inquiry Triage.md"`).
  `{:error, :not_found}` outside `icm/Workflows/`, missing, or without a
  parseable frontmatter block.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(icm_rel_path) do
    with {:ok, %{path: workspace}} <- Manager.current(),
         true <- valid_workflow_path?(icm_rel_path),
         {:ok, real} <- Valea.Paths.resolve_real(icm_rel_path, workspace),
         true <- under_workflows_dir?(real, workspace),
         abs <- Path.join(workspace, icm_rel_path),
         true <- File.regular?(abs),
         %{} = wf <- parse(abs, workspace) do
      {:ok, wf}
    else
      _ -> {:error, :not_found}
    end
  end

  # Cheap lexical pre-filter — NOT the containment check. A path can lexically
  # start with "icm/Workflows/" and end in ".md" while still traversing out
  # via "..", so this only short-circuits the obviously-wrong case before the
  # real `resolve_real/2` + `under_workflows_dir?/2` checks below.
  defp valid_workflow_path?(path) do
    String.starts_with?(path, @dir <> "/") and String.ends_with?(path, ".md")
  end

  # Confirms the realpath-resolved target is actually inside icm/Workflows/,
  # not merely inside the workspace — a path like
  # "icm/Workflows/../Offers/x.md" resolves within the workspace (so a bare
  # workspace-containment check would pass it) but lands outside the
  # Workflows directory and must still be rejected.
  defp under_workflows_dir?(real, workspace) do
    case Valea.Paths.resolve_real(@dir, workspace) do
      {:ok, dir_real} -> real == dir_real or String.starts_with?(real, dir_real <> "/")
      _ -> false
    end
  end

  defp workflow_files(workspace) do
    workspace
    |> Path.join(@dir)
    |> Path.join("*.md")
    |> Path.wildcard()
  end

  defp parse(abs, workspace) do
    with {:ok, content} <- File.read(abs),
         {block, body} <- Valea.ICM.split_frontmatter(content),
         %{} = fm <- parse_frontmatter(block) do
      %{
        path: Path.relative_to(abs, workspace),
        name: name_of(body, abs),
        description: description_of(body),
        enabled: !!Map.get(fm, "enabled", false),
        trigger: Map.get(fm, "trigger", %{}),
        sources: Map.get(fm, "sources", []),
        risk_level: Map.get(fm, "risk_level"),
        approval: Map.get(fm, "approval", %{}),
        steps_preview: steps_preview_of(body)
      }
    else
      _ -> nil
    end
  end

  defp parse_frontmatter(""), do: nil

  defp parse_frontmatter(block) do
    yaml = block |> String.trim_leading("---\n") |> String.trim_trailing("---\n")

    case YamlElixir.read_from_string(yaml) do
      {:ok, map} when is_map(map) -> map
      _ -> nil
    end
  end

  defp name_of(body, abs) do
    body
    |> String.split("\n")
    |> Enum.find_value(fn
      "# " <> title -> String.trim(title)
      _ -> nil
    end) || Path.basename(abs, ".md")
  end

  defp description_of(body) do
    lines = String.split(body, "\n")

    case Enum.drop_while(lines, &(not h1?(&1))) do
      [_h1 | rest] -> paragraph_after(rest)
      [] -> nil
    end
  end

  defp h1?(line), do: String.starts_with?(line, "# ")

  defp paragraph_after(lines) do
    text =
      lines
      |> Enum.drop_while(&(String.trim(&1) == ""))
      |> Enum.take_while(&(String.trim(&1) != "" and not String.starts_with?(&1, "#")))
      |> Enum.map_join(" ", &String.trim/1)

    if text == "", do: nil, else: text
  end

  defp steps_preview_of(body) do
    case Enum.drop_while(String.split(body, "\n"), &(String.trim(&1) != "## Process")) do
      [_heading | rest] -> numbered_items(rest)
      [] -> []
    end
  end

  defp numbered_items(lines) do
    lines
    |> Enum.take_while(&(not String.starts_with?(String.trim(&1), "#")))
    |> Enum.map(&Regex.run(~r/^\d+\.\s+(.+)$/, String.trim(&1)))
    |> Enum.filter(& &1)
    |> Enum.map(fn [_, text] -> text end)
  end
end
