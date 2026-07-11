defmodule Valea.Workspace.Scaffold do
  @moduledoc """
  Creates and validates workspace folders from the priv/workspace_template
  seed. The workspace is the user's property: everything here must remain
  plain, readable files.
  """

  @marker_dirs ~w(icm queue logs queue/staging queue/processing)

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
      # config/workspace.yaml ships with `id: TEMPLATE`; a real workspace
      # gets version 3 + a fresh, persistent UUID here (keychain entries key
      # on it, so it must survive the folder being moved or renamed — see the
      # mail design spec, §Credentials). The Migration keeps it stable on
      # every subsequent open (never regenerates an existing id).
      File.write!(
        Path.join(target, "config/workspace.yaml"),
        "version: 3\nid: #{Ecto.UUID.generate()}\n"
      )

      # Managed Claude settings exist from the moment a workspace is
      # scaffolded; Migration keeps them in sync on every subsequent open.
      Valea.Agents.ClaudeSettings.write!(target)
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
