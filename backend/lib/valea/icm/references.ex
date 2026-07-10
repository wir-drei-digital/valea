defmodule Valea.ICM.References do
  @moduledoc """
  Finds and rewrites workflow references to icm pages/folders.

  Workflow YAML is treated as opaque text here — sources reference icm
  content via literal `icm/<rel_path>` strings (see
  `priv/workspace_template/workflows/*.yaml`), so scanning/rewriting by
  substring is both simpler and more robust than parsing YAML and chasing
  its structure. `rewrite/2` is a plain string replace, not aware of YAML
  syntax, so callers must pass matchable substrings (see the boundary
  handling in `Valea.ICM.rename/2` for folder renames).
  """

  alias Valea.Workspace.Manager

  @name_regex ~r/^name:\s*(.+)$/m

  @doc """
  Lists the workflows that reference `rel_path` (an icm-relative path),
  by scanning every `{workspace}/workflows/*.yaml` for the literal string
  `icm/<rel_path>`.

  Returns `{:ok, [%{file: filename, name: display_name}]}`, sorted by
  filename. `display_name` is read from the YAML's top-level `name:` key,
  falling back to the filename when absent.
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

  Returns `{:ok, [updated_filenames]}`, sorted.
  """
  def rewrite(old_rel, new_rel) do
    with {:ok, dir} <- workflows_dir() do
      old_needle = "icm/" <> old_rel
      new_needle = "icm/" <> new_rel

      updated =
        dir
        |> workflow_files()
        |> Enum.filter(fn abs -> File.read!(abs) =~ needle_pattern(old_needle) end)
        |> Enum.map(fn abs ->
          content = File.read!(abs)
          rewritten = String.replace(content, old_needle, new_needle)
          atomic_write(abs, rewritten)
          Path.basename(abs)
        end)
        |> Enum.sort()

      {:ok, updated}
    end
  end

  defp needle_pattern(needle), do: Regex.compile!(Regex.escape(needle))

  defp workflow_files(dir) do
    dir
    |> Path.join("*.yaml")
    |> Path.wildcard()
    |> Enum.sort()
  end

  defp describe_workflow(abs) do
    content = File.read!(abs)

    name =
      case Regex.run(@name_regex, content) do
        [_, captured] -> String.trim(captured)
        nil -> Path.basename(abs)
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
      {:ok, %{path: ws}} -> {:ok, Path.join(ws, "workflows")}
      {:error, :no_workspace} -> {:error, :no_workspace}
    end
  end
end
