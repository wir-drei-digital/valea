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
  old single hardcoded `icm/Workflows/<file>.md`) for an EMBEDDED mount, or
  the ABSOLUTE physical `<root>/Workflows/<file>.md` for an EXTERNAL
  (`rel_root: nil`) mount (A2-T5b) — external content is addressed by its
  resolved absolute path in this registry, same as everywhere else. Every
  entry carries a `mount` field — the owning mount's manifest display name
  (`manifest.name`) — for provenance. Because `path` is namespaced by mount
  (by directory prefix or by absolute root), two mounts may each have a
  same-named `Workflows/<file>.md` without one shadowing the other.

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
  alias Valea.Workspace.Manager

  # The seeded workflow's filename — stable across mounts (T8's scaffold
  # seeds it at `mounts/<slug>/Workflows/New Inquiry Triage.md`; a
  # by-reference or hand-authored mount could seed its own copy under a
  # different mount name). `triage_path/0,1` matches on this basename alone,
  # deliberately mount-agnostic — see their docs.
  @triage_filename "New Inquiry Triage.md"

  @doc "All workflow contracts across every enabled mount, `{:ok, []}` when no workspace is open."
  @spec list() :: {:ok, [map()]}
  def list do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, list(ws)}
      {:error, :no_workspace} -> {:ok, []}
    end
  end

  @doc "Pure form of `list/0` — every workflow contract across `workspace`'s enabled mounts, sorted by path."
  @spec list(workspace :: String.t()) :: [map()]
  def list(workspace) when is_binary(workspace) do
    workspace
    |> Mounts.enabled()
    |> Enum.flat_map(&workflows_for_mount/1)
    |> Enum.sort_by(& &1.path)
  end

  @doc """
  The workspace-relative path of the seeded New Inquiry Triage workflow, or
  `nil` when no enabled mount has one — the discovery `Valea.Cockpit` and
  `Valea.Mail.Doctor` both use in place of the old hardcoded
  `icm/Workflows/New Inquiry Triage.md` (Task A-T13).

  Picks the FIRST match in `list/0`'s own sort order (by `path`, which
  sorts by owning mount name first since every path is prefixed
  `mounts/<name>/...` — i.e. the first enabled mount, alphabetically, that
  has a `Workflows/New Inquiry Triage.md`). A mount earlier in that order
  without the file is skipped, not a dead end — see `triage_path/1`'s
  sibling doc.
  """
  @spec triage_path() :: String.t() | nil
  def triage_path do
    {:ok, workflows} = list()
    find_triage(workflows)
  end

  @doc "Pure form of `triage_path/0` for `workspace`."
  @spec triage_path(workspace :: String.t()) :: String.t() | nil
  def triage_path(workspace) when is_binary(workspace) do
    workspace |> list() |> find_triage()
  end

  defp find_triage(workflows) do
    case Enum.find(workflows, &(Path.basename(&1.path) == @triage_filename)) do
      nil -> nil
      wf -> wf.path
    end
  end

  @doc """
  One workflow contract by its `list/0`-shaped `path` (workspace-relative
  `"mounts/primary/Workflows/New Inquiry Triage.md"` for an embedded mount,
  or the ABSOLUTE physical `<root>/Workflows/<file>.md` for an external one,
  A2-T5b). Resolves the owning mount via `Mounts.mount_for/1` — for an
  embedded path, regardless of that mount's enabled state (see moduledoc
  DECISION); for an absolute external path, `mount_for/1`'s own attribution
  rule requires an ENABLED, non-degraded mount (mirrors `Valea.ICM`'s editor
  ops, A2-T5b binding semantic 2) — a disabled/degraded external mount's
  path simply fails to attribute and falls through to `:not_found` below,
  same as any other unrecognized path. `{:error, :not_found}` when the path
  doesn't name a (currently eligible) mount, doesn't land under that
  mount's `Workflows/`, is missing, or has no parseable frontmatter block.
  """
  @spec get(String.t()) :: {:ok, map()} | {:error, :not_found}
  def get(rel_path) do
    with {:ok, mount} <- Mounts.mount_for(rel_path),
         %Manifest{} <- mount.manifest,
         mount_rel <- mount_relative(rel_path, mount),
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

  # The path relative to `mount`'s OWN root. Mirrors `Valea.ICM`'s private
  # `mount_relative/2` (kept local for the same reason `Valea.ICM.References`
  # keeps its own copy too: a small, self-contained helper, not worth a
  # shared dependency for):
  #
  #   * embedded: strips the leading `mounts/<name>` segment off the
  #     workspace-relative `rel_path`.
  #   * external (A2-T5b, `rel_root: nil`): strips `mount.root` itself off
  #     the ABSOLUTE `rel_path`.
  defp mount_relative(rel_path, %{rel_root: nil, root: root}) do
    cond do
      rel_path == root -> ""
      String.starts_with?(rel_path, root <> "/") -> String.trim_leading(rel_path, root <> "/")
      true -> rel_path
    end
  end

  defp mount_relative(rel_path, _mount) do
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
        path: workflow_path(mount, abs),
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

  # A workflow's `list/0`-shaped `path`: workspace-relative (`mounts/<name>/…`)
  # for an embedded mount; `abs` itself (already the absolute physical path —
  # it came straight off `mount.root`'s own glob/join) for an external one
  # (A2-T5b).
  defp workflow_path(%{rel_root: nil}, abs), do: abs
  defp workflow_path(mount, abs), do: Path.join(mount.rel_root, Path.relative_to(abs, mount.root))

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
