defmodule Valea.App.Config do
  @moduledoc """
  App-level (NOT workspace-level) configuration: which workspaces exist and
  which was opened last. A tiny JSON file in the OS user-data dir — this is
  the only state that lives outside a workspace, by design (the app must know
  where workspaces are before any workspace is open).
  """

  @file_name "config.json"
  @defaults %{"known_workspaces" => [], "last_opened" => nil}

  def dir do
    case System.get_env("VALEA_APP_DIR") do
      nil -> :filename.basedir(:user_data, "valea")
      override -> override
    end
  end

  def read do
    with {:ok, raw} <- File.read(Path.join(dir(), @file_name)),
         {:ok, %{} = data} <- Jason.decode(raw) do
      Map.merge(@defaults, Map.take(data, Map.keys(@defaults)))
    else
      _ -> @defaults
    end
  end

  def record_opened(path, name) do
    config = read()

    entry = %{
      "path" => path,
      "name" => name,
      "last_opened_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    known =
      [entry | Enum.reject(config["known_workspaces"], &(&1["path"] == path))]

    write(%{config | "known_workspaces" => known, "last_opened" => path})
  end

  def clear_last_opened do
    write(%{read() | "last_opened" => nil})
  end

  def recent do
    read()["known_workspaces"]
    |> Enum.filter(&File.dir?(&1["path"]))
    |> Enum.sort_by(& &1["last_opened_at"], :desc)
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
