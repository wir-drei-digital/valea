defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders.

  `create/3` scaffolds the v5 hidden-workspace shape from
  `priv/workspace_template`: a bare marker tree (`config/`, `sources/`,
  `logs/`, `runtime/`) plus a rendered `config/workspace.yaml`
  (`version: 5`, the given `id`/`name`, `icms: {}`). No starter mount, no
  root `AGENTS.md`/`CLAUDE.md`/`MOUNTS.md`, no `.claude/` — ICMs are
  declared into `icms:` (`Valea.Workspace.Manager`'s own task), not seeded
  as a mount on disk.
  """

  @marker_dirs ~w(config sources logs runtime)

  def template_dir, do: Path.join(:code.priv_dir(:valea), "workspace_template")

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

  @doc """
  Lowercase, ascii-fold (NFD decomposition + stripping combining marks),
  non-alphanumeric runs collapse to a single `-`, leading/trailing `-`
  trimmed — mirrors `Valea.Mail.MessageFile`'s `from_slug/1`. A name with
  no alphanumeric characters at all (e.g. "!!!") falls back to "mount"
  rather than minting an empty/degenerate directory name.

  Public so `Valea.Mounts.unique_mount_key/2` and `Valea.Workspace.Manager`
  can derive a directory/mount-key slug the same way a fresh scaffold names
  its starter mount, without duplicating this logic.
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
end
