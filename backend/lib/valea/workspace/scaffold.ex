defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders from the priv/workspace_template
  seed. The workspace is the user's property: everything here must remain
  plain, readable files.
  """

  @marker_dirs ~w(icm queue logs)

  def template_dir, do: Path.join(:code.priv_dir(:valea), "workspace_template")

  def create(target) do
    cond do
      File.exists?(target) and not empty_dir?(target) -> {:error, :target_not_empty}
      true -> do_create(target)
    end
  end

  def valid?(path) do
    File.dir?(path) and Enum.all?(@marker_dirs, &File.dir?(Path.join(path, &1)))
  end

  def inspect_summary(path) do
    %{
      valid: valid?(path),
      icm_pages: count_files(Path.join(path, "icm"), "**/*.md"),
      workflows: count_files(Path.join(path, "icm/Workflows"), "*.md"),
      queue_pending: count_files(Path.join(path, "queue/pending"), "*.json"),
      has_audit_log: File.exists?(Path.join(path, "logs/audit.jsonl"))
    }
  end

  defp do_create(target) do
    with :ok <- File.mkdir_p(target),
         {:ok, _} <- File.cp_r(template_dir(), target) do
      # template ships the gitignore un-dotted so tooling never ignores
      # template files; the real workspace gets the dotted name
      File.rename(Path.join(target, "gitignore"), Path.join(target, ".gitignore"))
      :ok
    else
      {:error, reason} -> {:error, reason}
      {:error, reason, _file} -> {:error, reason}
    end
  end

  defp empty_dir?(path), do: File.dir?(path) and File.ls!(path) == []

  defp count_files(dir, glob) do
    if File.dir?(dir), do: dir |> Path.join(glob) |> Path.wildcard() |> length(), else: 0
  end
end
