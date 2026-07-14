defmodule Valea.Workflows do
  @moduledoc """
  Reads workflow contracts from every mount's `Workflows/*.md` — parsed
  frontmatter (trigger, sources, risk_level, approval) plus a body-derived
  preview (H1 name, first paragraph description, numbered `## Process`
  steps). The filesystem is the source of truth; a `Workflows/` page with
  no frontmatter is not a contract (skipped by `list/0`, `{:error,
  :not_found}` from `get/2`). `Valea.Workflows.Runner` executes a workflow
  this module describes.

  `list/0` unions `Workflows/*.md` across `Valea.Mounts.enabled/0` — one
  glob per mount, sorted by the union's `resolved_path`. Every mount is now
  BY-REFERENCE (external, `Valea.Mounts`'s "Compatibility shim" section:
  `rel_root` is always `nil`), so `resolved_path` is always an absolute
  physical path.

  Task 7.1 re-keys the registry: a workflow's identity is `{icm_id,
  relative_path}` — `icm_id` the owning mount's manifest `id` (a stable
  UUID that survives the ICM being moved or re-mounted under a different
  `mount_key`), `relative_path` the ICM-relative `"Workflows/<file>.md"`.
  Each `list/0,1` entry ALSO carries `mount_key` (the workspace-local
  `icms:` config key — needed to address the ICM by `get/2`, since
  `Mounts.mount_by_key/2` is keyed by it, not by `icm_id`) and
  `resolved_path` (the current absolute path, for direct filesystem
  access/display — NOT part of the identity, since it changes if the ICM
  folder moves and mount_key/icm_id do not). The old single opaque `path`
  field (and the `mount` display-name field) are gone; a caller that wants
  the owning ICM's display name looks it up via `Valea.Mounts.mount_by_key/2`
  itself.

  DECISION (mirrors `Valea.ICM`'s DECISION for `page/1`, T3): `list/0` uses
  `Mounts.enabled/0`, so a DISABLED (or degraded) mount's workflows drop
  out of it entirely — the registry surfaces only the effective
  composition set. `get/2`, by contrast, resolves the owning mount via
  `Mounts.mount_by_key/2` REGARDLESS of that mount's enabled state (keyed
  lookup, not path-attribution, so there is no reason to require
  enabled/healthy the way `Mounts.mount_for/1`'s path-based attribution
  does) — a disabled mount's workflow contract still parses fine by
  explicit `{mount_key, relative_path}` (editor-style access), restoring
  the original pre-A2-T5b posture that path-based attribution had
  temporarily narrowed. Enabled-gating what a workflow RUN may actually
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

  # The reflection workflow's filename (Task B8) — same mount-agnostic
  # basename-match discovery as `@triage_filename`/`triage_path/0,1` above.
  # The starter-template contract file itself (seeding a mount's own
  # `Workflows/Distill Decisions.md`) is Task B9's job — until that lands,
  # `distill_path/0` returning `nil` on a fresh scaffold is expected, same
  # as `triage_path/0` would before Task A-T8 seeded ITS file.
  @distill_filename "Distill Decisions.md"

  @doc "All workflow contracts across every enabled mount, `{:ok, []}` when no workspace is open."
  @spec list() :: {:ok, [map()]}
  def list do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, list(ws)}
      {:error, :no_workspace} -> {:ok, []}
    end
  end

  @doc "Pure form of `list/0` — every workflow contract across `workspace`'s enabled mounts, sorted by `resolved_path`."
  @spec list(workspace :: String.t()) :: [map()]
  def list(workspace) when is_binary(workspace) do
    workspace
    |> Mounts.enabled()
    |> Enum.flat_map(&workflows_for_mount/1)
    |> Enum.sort_by(& &1.resolved_path)
  end

  @doc """
  The absolute `resolved_path` of the seeded New Inquiry Triage workflow, or
  `nil` when no enabled mount has one — the discovery `Valea.Cockpit` and
  `Valea.Mail.Doctor` both use in place of the old hardcoded
  `icm/Workflows/New Inquiry Triage.md` (Task A-T13).

  Picks the FIRST match in `list/0`'s own sort order (by `resolved_path`) —
  a `{mount_key, relative_path}` lookup over that same union, matching on
  `relative_path`'s basename. A mount earlier in that order without the
  file is skipped, not a dead end — see `triage_path/1`'s sibling doc.
  """
  @spec triage_path() :: String.t() | nil
  def triage_path do
    {:ok, workflows} = list()
    find_by_basename(workflows, @triage_filename)
  end

  @doc "Pure form of `triage_path/0` for `workspace`."
  @spec triage_path(workspace :: String.t()) :: String.t() | nil
  def triage_path(workspace) when is_binary(workspace) do
    workspace |> list() |> find_by_basename(@triage_filename)
  end

  @doc """
  The absolute `resolved_path` of the seeded Distill Decisions reflection
  workflow, or `nil` when no enabled mount has one — mirrors `triage_path/0`
  exactly (same first-match-in-`list/0`'s-own-sort-order, basename-matching
  `{mount_key, relative_path}` lookup; see its doc). Task B8's
  `distill_decisions` RPC uses this in place of a hardcoded path.
  """
  @spec distill_path() :: String.t() | nil
  def distill_path do
    {:ok, workflows} = list()
    find_by_basename(workflows, @distill_filename)
  end

  @doc "Pure form of `distill_path/0` for `workspace`."
  @spec distill_path(workspace :: String.t()) :: String.t() | nil
  def distill_path(workspace) when is_binary(workspace) do
    workspace |> list() |> find_by_basename(@distill_filename)
  end

  defp find_by_basename(workflows, filename) do
    case Enum.find(workflows, &(Path.basename(&1.relative_path) == filename)) do
      nil -> nil
      wf -> wf.resolved_path
    end
  end

  @doc """
  One workflow contract owned by `mount_key`, addressed by its ICM-relative
  `relative_path` (e.g. `"Workflows/New Inquiry Triage.md"`) — the current
  workspace's `{mount_key, relative_path}` identity pair (Task 7.1).

  Resolves the owning mount via `Mounts.mount_by_key/2` — a direct keyed
  lookup, so (unlike `list/0`) it does NOT require the mount to be enabled
  or healthy-attributed by path; only that `mount_key` names SOME mount
  with a loadable manifest (see moduledoc DECISION). `relative_path` is
  then containment-checked against THAT mount's OWN `Workflows/` directory
  (realpath-resolved, `..`/symlink-hardened — mirrors `Valea.ICM.contain/2`):

    * `{:error, :not_found}` — `mount_key` names no mount, or its manifest
      failed to load (degraded), or `relative_path` escapes the mount's own
      root entirely, or it lands inside the mount but the target file is
      missing / unreadable / has no parseable frontmatter block.
    * `{:error, :not_in_icm}` — `relative_path` resolves to somewhere
      INSIDE the mount but OUTSIDE that mount's own `Workflows/` directory
      (e.g. `"Workflows/../icm.yaml"`, or a page under `Offers/`) — the
      mount does not OWN this workflow.
  """
  @spec get(mount_key :: String.t(), relative_path :: String.t()) ::
          {:ok, map()} | {:error, :not_found | :not_in_icm}
  def get(mount_key, relative_path)
      when is_binary(mount_key) and is_binary(relative_path) do
    with {:ok, workspace} <- workspace_root(),
         mount when not is_nil(mount) <- Mounts.mount_by_key(workspace, mount_key),
         %Manifest{} <- mount.manifest,
         {:ok, real} <- Valea.Paths.resolve_real(relative_path, mount.root) do
      contained_get(real, mount, relative_path)
    else
      _ -> {:error, :not_found}
    end
  end

  defp workspace_root do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, ws}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # `real` already resolved+containment-checked against `mount.root` itself
  # (by `resolve_real/2` above) — this second check confirms it is
  # specifically inside the mount's OWN `Workflows/`, not merely inside the
  # mount (mirrors the pre-7.1 `under_workflows_dir?/2` containment gate).
  defp contained_get(real, mount, relative_path) do
    if under_workflows_dir?(real, mount.root) do
      abs = Path.join(mount.root, relative_path)

      with true <- File.regular?(abs),
           %{} = wf <- parse(abs, mount) do
        {:ok, wf}
      else
        _ -> {:error, :not_found}
      end
    else
      {:error, :not_in_icm}
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

  defp parse(abs, mount) do
    with {:ok, content} <- File.read(abs),
         {block, body} <- Valea.ICM.split_frontmatter(content),
         %{} = fm <- parse_frontmatter(block) do
      %{
        icm_id: mount.manifest.id,
        mount_key: mount.name,
        relative_path: Path.relative_to(abs, mount.root),
        resolved_path: abs,
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
