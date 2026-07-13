defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders.

  `create/3` scaffolds the CURRENT, v5 hidden-workspace shape from
  `priv/workspace_template`: a bare marker tree (`config/`, `sources/`,
  `queue/`, `logs/`, `runtime/`) plus a rendered `config/workspace.yaml`
  (`version: 5`, the given `id`/`name`, `icms: {}`). No starter mount, no
  root `AGENTS.md`/`CLAUDE.md`/`MOUNTS.md`, no `.claude/` — a fresh v5
  workspace carries none of the agent-routing files a mounts-based (v4)
  workspace did; ICMs are declared into `icms:` (Manager/Adopt's own
  tasks), not seeded as a mount on disk.

  `create/1` and `create/2` are the LEGACY (v4, all-are-mounts) scaffold,
  sourced from `priv/legacy_workspace_template` — kept working, byte-for-byte
  as before (starter mount, managed Claude settings, generated `MOUNTS.md`),
  because `Valea.Workspace.Manager` and `Valea.Workspace.Adopt` still open
  and adopt workspaces through this path pending their own id-based rework
  (a later task group). The legacy scaffold also creates the (empty) v5
  marker dir `runtime/`, so a legacy-scaffolded workspace still satisfies
  `valid?/1` immediately after creation, the same as it always has.
  """

  alias Valea.Mounts.Manifest
  alias Valea.Mounts.MountsMd

  @marker_dirs ~w(config sources queue logs queue/staging queue/processing runtime)

  def template_dir, do: Path.join(:code.priv_dir(:valea), "workspace_template")

  @doc "The pre-v5 (all-are-mounts) template `create/1`/`create/2` scaffold from."
  def legacy_template_dir, do: Path.join(:code.priv_dir(:valea), "legacy_workspace_template")

  @doc "Convenience form of the legacy `create/2`: names the workspace after the target directory's own basename."
  def create(target), do: create(target, Path.basename(target))

  @doc """
  LEGACY v4 scaffold (starter mount included) — see moduledoc. Fresh
  hidden workspaces should use `create/3`.
  """
  def create(target, name) do
    cond do
      File.exists?(target) and not empty_dir?(target) -> {:error, :target_not_empty}
      true -> do_create_legacy(target, name)
    end
  end

  @doc """
  Scaffolds a fresh v5 hidden workspace at `target`, named `name`, with
  the given persistent `id`. Builds the bare marker tree from
  `priv/workspace_template` and overwrites `config/workspace.yaml` with
  `version: 5`, the given `id`, the escaped `name`, and `icms: {}`.
  """
  @spec create(String.t(), String.t(), String.t()) :: :ok | {:error, term()}
  def create(target, name, id) do
    cond do
      File.exists?(target) and not empty_dir?(target) -> {:error, :target_not_empty}
      true -> do_create_v5(target, name, id)
    end
  end

  def valid?(path) do
    File.dir?(path) and Enum.all?(@marker_dirs, &File.dir?(Path.join(path, &1)))
  end

  def inspect_summary(path) do
    %{
      valid: valid?(path),
      icm_pages: count_icm_pages(path),
      workflows: count_matches(path, "mounts/*/Workflows/*.md"),
      queue_pending: count_files(Path.join(path, "queue/pending"), "*.json"),
      has_audit_log: File.exists?(Path.join(path, "logs/audit.jsonl"))
    }
  end

  defp do_create_v5(target, name, id) do
    with :ok <- File.mkdir_p(target),
         {:ok, _} <- File.cp_r(template_dir(), target) do
      # template ships the gitignore un-dotted so tooling never ignores
      # template files; the real workspace gets the dotted name
      File.rename(Path.join(target, "gitignore"), Path.join(target, ".gitignore"))

      File.write!(
        Path.join(target, "config/workspace.yaml"),
        "version: 5\nid: #{id}\nname: #{Valea.Yaml.escape(name)}\nicms: {}\n"
      )

      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  defp do_create_legacy(target, name) do
    with :ok <- File.mkdir_p(target),
         {:ok, _} <- File.cp_r(legacy_template_dir(), target) do
      # template ships the gitignore un-dotted so tooling never ignores
      # template files; the real workspace gets the dotted name
      File.rename(Path.join(target, "gitignore"), Path.join(target, ".gitignore"))
      # so a legacy-scaffolded workspace satisfies the (v5) marker-dir set
      # `valid?/1` checks, same as a v5 one — see moduledoc.
      File.mkdir_p!(Path.join(target, "runtime"))
      # config/workspace.yaml ships with `id: TEMPLATE`; a real workspace
      # gets version 4 + a fresh, persistent UUID here (keychain entries key
      # on it, so it must survive the folder being moved or renamed — see the
      # mail design spec, §Credentials). The Migration keeps it stable on
      # every subsequent open (never regenerates an existing id).
      File.write!(
        Path.join(target, "config/workspace.yaml"),
        "version: 4\nid: #{Ecto.UUID.generate()}\n"
      )

      mint_starter_mount!(target, name)

      # Managed Claude settings exist from the moment a workspace is
      # scaffolded; Migration keeps them in sync on every subsequent open.
      Valea.Agents.ClaudeSettings.write!(target)

      # The template ships a static MOUNTS.md placeholder (so the copied
      # tree is never momentarily without one); regenerate it now from the
      # REAL mount this scaffold just minted, same as every later
      # enable/disable/discovery-change caller (T7).
      MountsMd.regenerate(target)
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  # The template ships one seeded starter mount at `mounts/starter/` with a
  # placeholder manifest (`id: TEMPLATE`, `name: "Starter"`). A real
  # workspace gets a fresh uuid and the workspace's own name (preserving the
  # template's description) via `Manifest.write!/2` — mirroring the
  # workspace-id treatment above — then the directory itself is renamed to a
  # slug of that name, so a real workspace never ships a mount literally
  # named "starter" (unless the workspace name itself slugifies to that).
  defp mint_starter_mount!(target, name) do
    starter_dir = Path.join(target, "mounts/starter")
    {:ok, template_manifest} = Manifest.load(starter_dir)

    Manifest.write!(starter_dir, %{
      id: Ecto.UUID.generate(),
      name: name,
      description: template_manifest.description
    })

    mount_dir = Path.join(target, "mounts/#{slugify(name)}")
    unless mount_dir == starter_dir, do: File.rename!(starter_dir, mount_dir)
  end

  @doc """
  Lowercase, ascii-fold (NFD decomposition + stripping combining marks),
  non-alphanumeric runs collapse to a single `-`, leading/trailing `-`
  trimmed — mirrors `Valea.Mail.MessageFile`'s `from_slug/1`. A name with
  no alphanumeric characters at all (e.g. "!!!") falls back to "mount"
  rather than minting an empty/degenerate directory name.

  Public so `Valea.Workspace.Migration`'s v3→v4 step can name a migrated
  mount directory the same way a fresh scaffold names its starter one,
  without duplicating this logic.
  """
  @spec slugify(String.t()) :: String.t()
  def slugify(name) do
    slug =
      name
      |> String.normalize(:nfd)
      |> String.replace(~r/\p{Mn}/u, "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "-")
      |> String.trim("-")

    if slug == "", do: "mount", else: slug
  end

  defp empty_dir?(path), do: File.dir?(path) and File.ls!(path) == []

  defp count_files(dir, glob) do
    if File.dir?(dir), do: dir |> Path.join(glob) |> Path.wildcard() |> length(), else: 0
  end

  defp count_matches(path, glob), do: path |> Path.join(glob) |> Path.wildcard() |> length()

  # "ICM pages" = curated markdown content across every mount, excluding a
  # mount's own AGENTS.md/CLAUDE.md (self-description, not curated content)
  # and anything under `prompts/` (a distinct content type from ICM pages,
  # mirroring the pre-mounts top-level `icm/` vs `prompts/` split). A fresh
  # v5 workspace has no `mounts/` at all, so this (and `workflows` above)
  # naturally comes out 0 via `Path.wildcard/1` on an absent directory.
  defp count_icm_pages(path) do
    path
    |> Path.join("mounts/*/**/*.md")
    |> Path.wildcard()
    |> Enum.reject(&icm_page_excluded?/1)
    |> length()
  end

  defp icm_page_excluded?(abs) do
    String.contains?(abs, "/prompts/") or Path.basename(abs) in ["AGENTS.md", "CLAUDE.md"]
  end
end
