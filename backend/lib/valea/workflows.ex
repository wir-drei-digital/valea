defmodule Valea.Workflows do
  @moduledoc """
  Reads workflow contracts from every mount's `Workflows/*.md` — parsed
  frontmatter (trigger, sources, risk_level, approval) plus a body-derived
  preview (H1 name, first paragraph description, numbered `## Process`
  steps). The filesystem is the source of truth; a `Workflows/` page with
  no frontmatter is not a contract (skipped by `list/0`, `{:error,
  :not_found}` from `get/1`). `Valea.Workflows.Runner` executes a workflow
  this module describes.

  `list/0` unions `Workflows/*.md` across `Valea.Mounts.enabled/0` — one
  glob per mount, sorted by the union's `path`. Each entry's `path` is
  workspace-relative (`mounts/<name>/Workflows/<file>.md`, replacing the
  old single hardcoded `icm/Workflows/<file>.md`) and carries a `mount`
  field — the owning mount's manifest display name (`manifest.name`) — for
  provenance. Because `path` is namespaced by mount, two mounts may each
  have a same-named `Workflows/<file>.md` without one shadowing the other.

  DECISION (mirrors `Valea.ICM`'s DECISION for `page/1`, T3): `list/0` uses
  `Mounts.enabled/0`, so a DISABLED (or degraded) mount's workflows drop
  out of it entirely — the registry surfaces only the effective
  composition set. `get/1`, by contrast, resolves the owning mount via
  `Mounts.mount_for/1` REGARDLESS of that mount's enabled state: a disabled
  mount's workflow contract still parses fine by explicit path
  (editor-style access). Enabled-gating what a workflow RUN may actually
  execute is `Valea.Workflows.Runner`'s `ensure_enabled/1` check on the
  returned `enabled` frontmatter flag, not this lookup's concern.
  """

  alias Valea.Mounts
  alias Valea.Mounts.Manifest

  @doc "All workflow contracts across every enabled mount, `{:ok, []}` when no workspace is open."
  @spec list() :: {:ok, [map()]}
  def list do
    case Mounts.enabled() do
      {:ok, mounts} ->
        {:ok,
         mounts
         |> Enum.flat_map(&workflows_for_mount/1)
         |> Enum.sort_by(& &1.path)}

      {:error, :no_workspace} ->
        {:ok, []}
    end
  end

  @doc """
  One workflow contract by its workspace-relative path (as returned in
  `list/0`'s `path` field, e.g. `"mounts/primary/Workflows/New Inquiry
  Triage.md"`). Resolves the owning mount regardless of its enabled state
  (see moduledoc DECISION). `{:error, :not_found}` when the path doesn't
  name a real mount, doesn't land under that mount's `Workflows/`, is
  missing, or has no parseable frontmatter block.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(rel_path) do
    with {:ok, mount} <- Mounts.mount_for(rel_path),
         %Manifest{} <- mount.manifest,
         mount_rel <- mount_relative(rel_path),
         true <- valid_workflow_rel?(mount_rel),
         {:ok, real} <- Valea.Paths.resolve_real(mount_rel, mount.root),
         true <- under_workflows_dir?(real, mount.root),
         # `real` is realpath-resolved (symlinks followed, e.g. macOS's
         # /var -> /private/var) purely for the containment check above —
         # reads/parsing go through the LITERAL `abs` (mount.root's own,
         # unresolved, string form) so `parse/2`'s `Path.relative_to/2`
         # below has a matching prefix to strip. Mirrors the pre-mounts
         # `get/1`'s identical abs/real split.
         abs <- Path.join(mount.root, mount_rel),
         true <- File.regular?(abs),
         %{} = wf <- parse(abs, mount) do
      {:ok, wf}
    else
      _ -> {:error, :not_found}
    end
  end

  defp workflows_for_mount(%{manifest: %Manifest{}} = mount) do
    mount.root
    |> Path.join("Workflows")
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.map(&parse(&1, mount))
    |> Enum.reject(&is_nil/1)
  end

  # Defense in depth: skip mounts with degraded (non-Manifest) manifest.
  # Mounts.enabled/0 already filters these out, but guard here to be safe.
  defp workflows_for_mount(_mount), do: []

  # Cheap lexical pre-filter — NOT the containment check. A mount-relative
  # remainder can lexically start with "Workflows/" and end in ".md" while
  # still traversing out via "..", so this only short-circuits the
  # obviously-wrong case before the real `resolve_real/2` +
  # `under_workflows_dir?/2` checks below.
  defp valid_workflow_rel?(mount_rel) do
    String.starts_with?(mount_rel, "Workflows/") and String.ends_with?(mount_rel, ".md")
  end

  # Confirms the realpath-resolved target is actually inside the mount's
  # own Workflows/, not merely inside the mount's root — a path like
  # "Workflows/../Offers/x.md" resolves within the mount (so a bare
  # mount-containment check would pass it) but lands outside the Workflows
  # directory and must still be rejected.
  defp under_workflows_dir?(real, mount_root) do
    case Valea.Paths.resolve_real("Workflows", mount_root) do
      {:ok, dir_real} -> real == dir_real or String.starts_with?(real, dir_real <> "/")
      _ -> false
    end
  end

  # Strips the leading `mounts/<name>` segment off a workspace-relative
  # path, leaving the path relative to that mount's own root. Mirrors the
  # private `mount_relative/1` in `Valea.ICM` / `Valea.ICM.References` —
  # kept local for the same reason those keep their own copy: a small,
  # self-contained helper, not worth a shared dependency for.
  defp mount_relative(rel_path) do
    case Path.split(rel_path) do
      ["mounts", _name | rest] -> Enum.join(rest, "/")
      _ -> rel_path
    end
  end

  defp parse(abs, mount) do
    with {:ok, content} <- File.read(abs),
         {block, body} <- Valea.ICM.split_frontmatter(content),
         %{} = fm <- parse_frontmatter(block) do
      %{
        path: Path.join(mount.rel_root, Path.relative_to(abs, mount.root)),
        mount: mount.manifest.name,
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
