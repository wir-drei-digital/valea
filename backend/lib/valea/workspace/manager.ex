defmodule Valea.Workspace.Manager do
  @moduledoc """
  The open-workspace lifecycle. The app boots workspace-less; this GenServer
  opens/creates workspaces, starting the Repo against {workspace}/app.sqlite
  and running migrations. Loud, specific failures — a workspace is never
  presented as healthy when half-opened.
  """
  use GenServer

  alias Valea.App.Config
  alias Valea.Workspace.Scaffold

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  def create(parent_dir, name),
    do: GenServer.call(__MODULE__, {:create, parent_dir, name}, 30_000)

  def open(path), do: GenServer.call(__MODULE__, {:open, path}, 30_000)
  def close, do: GenServer.call(__MODULE__, :close)
  def current, do: GenServer.call(__MODULE__, :current)

  @impl true
  def init(_opts) do
    {:ok, %{workspace: nil, children: []}, {:continue, :auto_open}}
  end

  @impl true
  def handle_continue(:auto_open, state) do
    case Config.read()["last_opened"] do
      nil ->
        {:noreply, state}

      path ->
        case do_open(path, state) do
          {:ok, state} ->
            {:noreply, state}

          {:error, _reason} ->
            Config.clear_last_opened()
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_call({:create, parent_dir, name}, _from, state) do
    target = Path.join(parent_dir, name)

    with :ok <- Scaffold.create(target),
         {:ok, state} <- do_open(target, state) do
      {:reply, {:ok, state.workspace}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:open, path}, _from, state) do
    case do_open(path, state) do
      {:ok, state} -> {:reply, {:ok, state.workspace}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:close, _from, state) do
    {:reply, :ok, do_close(state)}
  end

  def handle_call(:current, _from, %{workspace: nil} = state) do
    {:reply, {:error, :no_workspace}, state}
  end

  def handle_call(:current, _from, %{workspace: ws} = state) do
    {:reply, {:ok, ws}, state}
  end

  defp do_open(path, state) do
    path = Path.expand(path)

    cond do
      not Scaffold.valid?(path) ->
        {:error, :not_a_workspace}

      true ->
        state = do_close(state)

        with {:ok, repo_pid} <- start_repo(path),
             :ok <- migrate() do
          info = %{path: path, name: Path.basename(path)}
          Config.record_opened(path, info.name)
          Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_opened, info})
          {:ok, %{state | workspace: info, children: [repo_pid]}}
        end
    end
  end

  defp do_close(%{workspace: nil} = state), do: state

  defp do_close(state) do
    Enum.each(state.children, fn pid ->
      DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, pid)
    end)

    Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_closed})
    %{state | workspace: nil, children: []}
  end

  defp start_repo(workspace_path) do
    spec = {Valea.Repo, database: Path.join(workspace_path, "app.sqlite"), pool_size: 5}

    case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:repo_start_failed, reason}}
    end
  end

  defp migrate do
    path = Ecto.Migrator.migrations_path(Valea.Repo)
    Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
    :ok
  rescue
    e -> {:error, {:migration_failed, Exception.message(e)}}
  end
end
