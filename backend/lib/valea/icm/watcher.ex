defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches {workspace}/icm and {workspace}/queue, broadcasting a debounced
  event per tree on its own PubSub topic:

    * a change under icm/ -> `{:icm_changed}` on `"icm"`
    * a change under queue/ -> `{:queue_changed}` on `"queue"`

  Each tree gets its own debounce timer so a burst of activity in one does
  not delay or coalesce with the other. Events carry no payload by design —
  consumers refetch (the ICM tree / queue list are cheap to rebuild and the
  fs events themselves are noisy).

  Started under `Valea.Workspace.Runtime` — it lives and dies with the open
  workspace, same as the audit writer and agent session supervisor.
  """
  use GenServer

  @debounce_ms 200

  def start_link({icm_path, queue_path}),
    do: GenServer.start_link(__MODULE__, {icm_path, queue_path}, name: __MODULE__)

  @impl true
  def init({icm_path, queue_path}) do
    {:ok, watcher} = FileSystem.start_link(dirs: [icm_path, queue_path])
    FileSystem.subscribe(watcher)

    # FSEvents (the macOS backend) reports paths through their PHYSICAL
    # (symlink-resolved) form — e.g. under `/private/var/...` even when the
    # directory was opened via a `/var/...` alias, as it commonly is under
    # the system temp dir. Resolving our reference paths the same way here,
    # once, keeps the prefix comparison in `under?/2` correct regardless of
    # which alias the caller passed in.
    {:ok,
     %{
       watcher: watcher,
       icm_path: canonical(icm_path),
       queue_path: canonical(queue_path),
       icm_timer: nil,
       queue_timer: nil
     }}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    cond do
      under?(path, state.queue_path) -> {:noreply, arm(:queue_timer, :flush_queue, state)}
      under?(path, state.icm_path) -> {:noreply, arm(:icm_timer, :flush_icm, state)}
      true -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush_icm, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})
    {:noreply, %{state | icm_timer: nil}}
  end

  def handle_info(:flush_queue, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "queue", {:queue_changed})
    {:noreply, %{state | queue_timer: nil}}
  end

  defp arm(timer_key, flush_msg, state) do
    if state[timer_key], do: Process.cancel_timer(state[timer_key])
    Map.put(state, timer_key, Process.send_after(self(), flush_msg, @debounce_ms))
  end

  defp under?(path, dir), do: path == dir or String.starts_with?(path, dir <> "/")

  defp canonical(path) do
    case Valea.Paths.resolve_real(".", path) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> path
    end
  end
end
