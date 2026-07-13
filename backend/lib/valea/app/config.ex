defmodule Valea.App.Config do
  @moduledoc """
  App-level (NOT workspace-level) configuration: which workspaces exist and
  which was opened last. A tiny JSON file in the OS user-data dir — this is
  the only state that lives outside a workspace, by design (the app must know
  where workspaces are before any workspace is open).
  """

  @file_name "config.json"
  @default_harness_command ["claude-agent-acp"]
  @defaults %{
    "known_workspaces" => [],
    "last_opened" => nil,
    "harness_command" => @default_harness_command,
    "harness_command_approved" => true
  }

  def dir do
    case System.get_env("VALEA_APP_DIR") do
      nil -> :filename.basedir(:user_data, "valea")
      override -> override
    end
  end

  @doc "App-owned parent directory for hidden workspace folders — `dir()/workspaces`."
  def workspaces_dir, do: Path.join(dir(), "workspaces")

  def read do
    with {:ok, raw} <- File.read(Path.join(dir(), @file_name)),
         {:ok, %{} = data} <- Jason.decode(raw) do
      Map.merge(@defaults, Map.take(data, Map.keys(@defaults)))
    else
      _ -> @defaults
    end
  end

  @doc """
  Id-keyed upsert into `known_workspaces`, setting `last_opened` to the id.
  `path` stays in the registry as the internal on-disk locator the Manager
  needs to boot the workspace — it is never sent to or accepted from the
  UI, which addresses workspaces by `id` only (see `workspace_by_id/1`,
  `last_opened_id/0`).
  """
  def record_opened(%{id: id, name: name, slug: slug, path: path}) do
    config = read()

    entry = %{
      "id" => id,
      "name" => name,
      "slug" => slug,
      "path" => path,
      "last_opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    known =
      [entry | Enum.reject(config["known_workspaces"], &(&1["id"] == id))]

    write(%{config | "known_workspaces" => known, "last_opened" => id})
  end

  def clear_last_opened do
    write(%{read() | "last_opened" => nil})
  end

  @doc "The known-workspace registry entry for `id`, or `nil` if not found."
  def workspace_by_id(id), do: Enum.find(read()["known_workspaces"], &(&1["id"] == id))

  @doc "The id of the last-opened workspace, or `nil`."
  def last_opened_id, do: read()["last_opened"]

  def recent do
    read()["known_workspaces"]
    |> Enum.filter(&File.dir?(&1["path"]))
    |> Enum.sort_by(& &1["last_opened_at"], :desc)
  end

  @doc """
  The agent harness executable + argv, as `[cmd | args]`. TRUSTED app
  config only — this is never read from workspace files. Defaults to
  `["claude-agent-acp"]`, resolved on PATH at spawn time.
  """
  def harness_command, do: read()["harness_command"]

  @doc "Whether the current harness_command has been consented to via the UI."
  def harness_command_approved?, do: read()["harness_command_approved"]

  @doc """
  Persists the harness command. Any value other than the default
  (`["claude-agent-acp"]`) requires fresh UI consent, so approval is reset
  to `false` on every change away from the default; setting it back to the
  default restores its implicit approval.
  """
  def set_harness_command(cmd) when is_list(cmd) and cmd != [] do
    approved = cmd == @default_harness_command

    write(%{
      read()
      | "harness_command" => cmd,
        "harness_command_approved" => approved
    })
  end

  defp write(config) do
    File.mkdir_p!(dir())
    path = Path.join(dir(), @file_name)
    tmp = path <> ".tmp"
    File.write!(tmp, Jason.encode!(config, pretty: true))
    File.rename!(tmp, path)
    :ok
  end
end
