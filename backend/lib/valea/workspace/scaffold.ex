defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders from the priv/workspace_template
  seed. The workspace is the user's property: everything here must remain
  plain, readable files.

  Every mount is a real mount (Plan A, "all mounts"): the template ships one
  seeded starter mount at `mounts/starter/` (rich demo content — clients,
  offers, policies, pricing, workflows — under a placeholder `icm.yaml`).
  `create/2` mints that mount a fresh uuid and the workspace's own name,
  renames its directory to a slug of that name, and regenerates the
  workspace's `MOUNTS.md` — so a freshly scaffolded workspace never ships a
  top-level `icm/` or `prompts/` tree, only `mounts/<slug>/`.
  """

  alias Valea.Mounts.Manifest
  alias Valea.Mounts.MountsMd

  @marker_dirs ~w(mounts queue logs queue/staging queue/processing)

  def template_dir, do: Path.join(:code.priv_dir(:valea), "workspace_template")

  @doc "Convenience form of `create/2`: names the workspace after the target directory's own basename."
  def create(target), do: create(target, Path.basename(target))

  @doc """
  Scaffolds a new workspace at `target`, named `name` (the workspace's own
  display name — becomes the starter mount's `icm.yaml` `name:`, and is
  slugified for that mount's directory name; see `mint_starter_mount!/2`).
  """
  def create(target, name) do
    cond do
      File.exists?(target) and not empty_dir?(target) -> {:error, :target_not_empty}
      true -> do_create(target, name)
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

  defp do_create(target, name) do
    with :ok <- File.mkdir_p(target),
         {:ok, _} <- File.cp_r(template_dir(), target) do
      # template ships the gitignore un-dotted so tooling never ignores
      # template files; the real workspace gets the dotted name
      File.rename(Path.join(target, "gitignore"), Path.join(target, ".gitignore"))
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
  # mirroring the pre-mounts top-level `icm/` vs `prompts/` split).
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
