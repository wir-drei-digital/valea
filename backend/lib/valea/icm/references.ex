defmodule Valea.ICM.References do
  @moduledoc """
  Finds and rewrites workflow references to icm pages/folders.

  Workflow pages are treated as opaque text here — sources reference icm
  content via literal `icm/<rel_path>` strings inside their YAML
  frontmatter (see `priv/workspace_template/icm/Workflows/*.md`), so
  scanning/rewriting by substring is both simpler and more robust than
  parsing YAML and chasing its structure. `rewrite/2` is a plain string
  replace, not aware of YAML syntax, so callers must pass matchable
  substrings (see the boundary handling in `Valea.ICM.rename/2` for folder
  renames).
  """

  alias Valea.Workspace.Manager

  @name_regex ~r/^name:\s*(.+)$/m

  @doc """
  Lists the workflows that reference `rel_path` (an icm-relative path),
  by scanning every `{workspace}/icm/Workflows/*.md` for the literal string
  `icm/<rel_path>`.

  Returns `{:ok, [%{file: filename, name: display_name}]}`, sorted by
  filename. `display_name` is read from a top-level `name:` line in the
  page (a legacy YAML convention), falling back to the filename without
  its extension when absent — which is every current page, since the
  frontmatter carries no `name:` key.
  """
  def referencing_workflows(rel_path) do
    with {:ok, dir} <- workflows_dir() do
      needle = "icm/" <> rel_path

      refs =
        dir
        |> workflow_files()
        |> Enum.filter(fn abs -> File.read!(abs) =~ needle_pattern(needle) end)
        |> Enum.map(&describe_workflow/1)
        |> Enum.sort_by(& &1.file)

      {:ok, refs}
    end
  end

  @doc """
  Rewrites every workflow referencing `old_rel` (an icm-relative path) to
  reference `new_rel` instead, by literally replacing `icm/<old_rel>` with
  `icm/<new_rel>` and atomically writing the file back.

  Returns `{:ok, [updated_filenames]}` (sorted) on success, or
  `{:error, {:rewrite_failed, file_basename, reason}}` if any write fails.

  Note: A rewrite failure leaves already-rewritten files on disk; the caller
  must surface the error to the user (who can decide whether to retry, rollback
  via version control, or manually intervene).
  """
  def rewrite(old_rel, new_rel) do
    with {:ok, dir} <- workflows_dir() do
      old_needle = "icm/" <> old_rel
      new_needle = "icm/" <> new_rel

      files_to_rewrite =
        dir
        |> workflow_files()
        |> Enum.filter(fn abs -> File.read!(abs) =~ needle_pattern(old_needle) end)

      rewrite_all(files_to_rewrite, old_needle, new_needle)
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

  defp workflows_dir do
    case Manager.current() do
      {:ok, %{path: ws}} -> {:ok, Path.join(ws, "icm/Workflows")}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end
end
