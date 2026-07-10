defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches {workspace}/icm and broadcasts a debounced {:icm_changed} on the
  "icm" PubSub topic. Consumers refetch the tree — events carry no payload
  by design (the tree is cheap to rebuild and the fs events are noisy).

  Started under `Valea.Workspace.Runtime` — it lives and dies with the open
  workspace, same as the audit writer and agent session supervisor.
  """
  use GenServer

  @debounce_ms 200

  def start_link(icm_path), do: GenServer.start_link(__MODULE__, icm_path, name: __MODULE__)

  @impl true
  def init(icm_path) do
    {:ok, watcher} = FileSystem.start_link(dirs: [icm_path])
    FileSystem.subscribe(watcher)
    {:ok, %{watcher: watcher, timer: nil}}
  end

  @impl true
  def handle_info({:file_event, _pid, {_path, _events}}, state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    {:noreply, %{state | timer: Process.send_after(self(), :flush, @debounce_ms)}}
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})
    {:noreply, %{state | timer: nil}}
  end
end
