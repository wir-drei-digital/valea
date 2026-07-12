defmodule Valea.ICM.References do
  @moduledoc """
  Finds and rewrites workflow references to ICM pages/folders — scoped to a
  single mount.

  A workflow page's `sources:` frontmatter references ICM content via a
  literal, ICM-relative path string: `<inner>`, relative to the referencing
  workflow's OWN mount root (a workflow in `mounts/primary/Workflows/`
  points at a page via `Offers/X.md`, never `mounts/primary/Offers/X.md`).
  `referencing_workflows/1` and `rewrite/2` both take a workspace-relative
  `mounts/<name>/<inner>` path, resolve the owning mount via
  `Valea.Mounts.mount_for/1`, and scan/rewrite only THAT mount's
  `Workflows/*.md` files for the `<inner>` needle — a same-named page in a
  different mount is never matched (mount isolation is by directory, not by
  the needle string).

  Workflow pages are treated as opaque text here — scanning/rewriting by
  substring is both simpler and more robust than parsing YAML and chasing
  its structure. `rewrite/2` is a plain string replace, not aware of YAML
  syntax, so callers must pass matchable substrings (see the boundary
  handling in `Valea.ICM.rename/2` for folder renames).
  """

  alias Valea.Mounts

  @name_regex ~r/^name:\s*(.+)$/m

  @doc """
  Lists the workflows — within `rel_path`'s own mount — that reference it,
  by scanning every `{mount_root}/Workflows/*.md` for the literal
  ICM-relative needle.

  `rel_path` is workspace-relative (`mounts/<name>/<inner>`); the string
  scanned for is `<inner>` alone (no `mounts/<name>` prefix).

  Returns `{:ok, [%{file: filename, name: display_name}]}`, sorted by
  filename. `display_name` is read from a top-level `name:` line in the
  page (a legacy YAML convention), falling back to the filename without
  its extension when absent — which is every current page, since the
  frontmatter carries no `name:` key.

  Errors: `{:error, :outside_workspace}` when `rel_path` doesn't name a
  mount discovered in the current workspace; `{:error, :no_workspace}`
  when no workspace is open.
  """
  def referencing_workflows(rel_path) do
    with {:ok, mount} <- resolve_mount(rel_path) do
      needle = mount_relative(rel_path)

      refs =
        mount
        |> workflows_dir()
        |> workflow_files()
        |> Enum.filter(fn abs -> File.read!(abs) =~ needle_pattern(needle) end)
        |> Enum.map(&describe_workflow/1)
        |> Enum.sort_by(& &1.file)

      {:ok, refs}
    end
  end

  @doc """
  Rewrites every workflow — within `old_rel`'s mount — referencing
  `old_rel` to reference `new_rel` instead, by literally replacing the
  `<inner>` needle and atomically writing the file back.

  `old_rel` and `new_rel` are both workspace-relative (`mounts/<name>/<inner>`)
  and MUST name the same mount — a rename never crosses mounts.

  Returns `{:ok, [updated_filenames]}` (sorted) on success,
  `{:error, :cross_mount_rename}` when `old_rel`/`new_rel` name different
  mounts, `{:error, :outside_workspace}` / `{:error, :no_workspace}` from
  mount resolution, or `{:error, {:rewrite_failed, file_basename, reason}}`
  if any write fails.

  Note: A rewrite failure leaves already-rewritten files on disk; the caller
  must surface the error to the user (who can decide whether to retry, rollback
  via version control, or manually intervene).
  """
  def rewrite(old_rel, new_rel) do
    with {:ok, old_mount} <- resolve_mount(old_rel),
         {:ok, new_mount} <- resolve_mount(new_rel),
         :ok <- same_mount(old_mount, new_mount) do
      old_needle = mount_relative(old_rel)
      new_needle = mount_relative(new_rel)

      files_to_rewrite =
        old_mount
        |> workflows_dir()
        |> workflow_files()
        |> Enum.filter(fn abs -> File.read!(abs) =~ needle_pattern(old_needle) end)

      rewrite_all(files_to_rewrite, old_needle, new_needle)
    end
  end

  defp same_mount(%{name: name}, %{name: name}), do: :ok
  defp same_mount(_old_mount, _new_mount), do: {:error, :cross_mount_rename}

  # `Mounts.mount_for/1` is attribution-only (per its own docs): it names
  # the mount `rel_path` points into without validating the rest of the
  # path. That is exactly what this module needs — it never turns
  # `rel_path` into a filesystem path itself, only strips its `mounts/<name>`
  # prefix to build a search/replace needle (see `mount_relative/1`); every
  # actual filesystem access below is confined to `mount.root/Workflows/*.md`,
  # already contained by construction via `workflow_files/1`'s glob.
  defp resolve_mount(rel_path) do
    case Mounts.mount_for(rel_path) do
      {:ok, mount} -> {:ok, mount}
      {:error, :not_in_mount} -> {:error, :outside_workspace}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end

  # Strips the leading `mounts/<name>` segment off a workspace-relative
  # path, leaving the path ICM-relative to that mount's own root — the
  # needle scanned/rewritten in Workflows pages. Mirrors the private
  # `mount_relative/1` in `Valea.ICM` — kept local rather than shared for
  # the same reason `atomic_write/2` below is: a small, self-contained
  # module, not worth a shared dependency for.
  defp mount_relative(rel_path) do
    case Path.split(rel_path) do
      ["mounts", _name | rest] -> Enum.join(rest, "/")
      _ -> rel_path
    end
  end

  defp rewrite_all(files, old_needle, new_needle) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn abs, {:ok, updated} ->
        content = File.read!(abs)
        rewritten = String.replace(content, old_needle, new_needle)

        case atomic_write(abs, rewritten) do
          :ok ->
            {:cont, {:ok, [Path.basename(abs) | updated]}}

          {:error, reason} ->
            {:halt, {:error, {:rewrite_failed, Path.basename(abs), reason}}}
        end
      end)

    case result do
      {:ok, updated} -> {:ok, Enum.sort(updated)}
      error -> error
    end
  end

  defp needle_pattern(needle), do: Regex.compile!(Regex.escape(needle))

  defp workflows_dir(mount), do: Path.join(mount.root, "Workflows")

  defp workflow_files(dir) do
    dir
    |> Path.join("*.md")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp describe_workflow(abs) do
    content = File.read!(abs)

    name =
      case Regex.run(@name_regex, content) do
        [_, captured] -> String.trim(captured)
        nil -> abs |> Path.basename() |> Path.rootname()
      end

    %{file: Path.basename(abs), name: name}
  end

  # Mirrors the private atomic_write in Valea.ICM (write to a `.tmp` sibling,
  # then rename over the target) — kept local rather than shared because
  # References is a small, self-contained module and the pattern is two
  # lines; not worth a shared dependency for.
  defp atomic_write(abs, bytes) do
    tmp = abs <> ".tmp"

    with :ok <- File.write(tmp, bytes),
         :ok <- File.rename(tmp, abs) do
      :ok
    end
  end
end
