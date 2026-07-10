defmodule Valea.Workspace.Manager do
  @moduledoc """
  The open-workspace lifecycle. The app boots workspace-less; this GenServer
  opens/creates workspaces, starting the Repo against {workspace}/app.sqlite,
  running migrations, and starting the ICM file watcher. Loud, specific
  failures — a workspace is never presented as healthy when half-opened.
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

          {:error, _reason, state} ->
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
      # Scaffold.create failed before any close — reply with the untouched state.
      {:error, reason} -> {:reply, {:error, reason}, state}
      # do_open closed the previous workspace before failing — reply with the
      # closed state so `current/0` never reports a dead workspace as open.
      {:error, reason, closed_state} -> {:reply, {:error, reason}, closed_state}
    end
  end

  def handle_call({:open, path}, _from, state) do
    case do_open(path, state) do
      {:ok, state} -> {:reply, {:ok, state.workspace}, state}
      {:error, reason, closed_state} -> {:reply, {:error, reason}, closed_state}
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

  # On any failure, returns `{:error, reason, state}` where `state` reflects
  # whether the previous workspace was closed. A failure BEFORE close carries
  # the untouched state; a failure AFTER close carries the closed state, so a
  # failed switch never leaves the Manager reporting a dead workspace as open.
  defp do_open(path, state) do
    path = Path.expand(path)

    cond do
      not Scaffold.valid?(path) ->
        {:error, :not_a_workspace, state}

      true ->
        state = do_close(state)
        open_workspace(path, state)
    end
  end

  # Starts children one at a time, tracking every started pid. If any step
  # fails, everything already started so far is rolled back before the
  # error is returned, so a half-opened workspace is never left running
  # under a name a future open/create could mistake for success. The ICM
  # file watcher is one more step here, accumulating onto `started` after
  # the repo.
  defp open_workspace(path, state) do
    case start_repo(path) do
      {:ok, repo_pid} -> open_workspace(path, state, [repo_pid])
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp open_workspace(path, state, started) do
    case migrate() do
      :ok -> open_workspace_watcher(path, state, started)
      {:error, reason} -> rollback_with(started, reason, state)
    end
  end

  defp open_workspace_watcher(path, state, started) do
    case start_watcher(path) do
      {:ok, watcher_pid} ->
        started = started ++ [watcher_pid]
        open_workspace_migrate(path, state, started)

      {:error, reason} ->
        rollback_with(started, reason, state)
    end
  end

  # Brings an existing workspace up to the current on-disk shape (new
  # marker dirs, converted workflow pages, managed Claude settings) before
  # it is presented as open. Runs after the repo/watcher are up (so it acts
  # on a fully mounted workspace) and before the open broadcast, so a
  # failure here rolls back exactly like a failed repo or watcher start —
  # never leaving a half-open workspace behind.
  defp open_workspace_migrate(path, state, started) do
    case Valea.Workspace.Migration.migrate(path) do
      {:ok, _version} ->
        info = %{path: path, name: Path.basename(path)}
        Config.record_opened(path, info.name)
        Phoenix.PubSub.broadcast(Valea.PubSub, "workspace", {:workspace_opened, info})
        {:ok, %{state | workspace: info, children: started}}

      {:error, reason} ->
        rollback_with(started, reason, state)
    end
  end

  defp rollback_with(started, reason, state) do
    rollback(started)
    {:error, reason, state}
  end

  defp rollback(pids) do
    Enum.each(pids, fn pid ->
      DynamicSupervisor.terminate_child(Valea.Workspace.DynamicSupervisor, pid)
    end)
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

  defp start_watcher(workspace_path) do
    spec = {Valea.ICM.Watcher, Path.join(workspace_path, "icm")}

    case DynamicSupervisor.start_child(Valea.Workspace.DynamicSupervisor, spec) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:watcher_start_failed, reason}}
    end
  end

  defp migrate do
    path =
      Application.get_env(:valea, :migrations_path) || Ecto.Migrator.migrations_path(Valea.Repo)

    Ecto.Migrator.run(Valea.Repo, path, :up, all: true)
    :ok
  rescue
    e -> {:error, {:migration_failed, Exception.message(e)}}
  end
end
