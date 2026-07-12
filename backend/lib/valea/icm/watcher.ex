defmodule Valea.ICM.Watcher do
  @moduledoc """
  Watches {workspace}/mounts and {workspace}/queue, broadcasting debounced
  events on their own PubSub topics:

    * any change under mounts/ -> `{:icm_changed}` on `"icm"` (unchanged
      contract — consumers refetch the grouped ICM tree, which now lives
      under `mounts/<name>/` instead of a single hardcoded `icm/` root)
    * a change that may affect the MOUNT SET itself — a top-level
      `mounts/<name>` directory added or removed, or a `mounts/<name>/icm.yaml`
      manifest touched — ALSO broadcasts `{:mounts_changed}` on `"mounts"`
      (discovery, the registry union, and MOUNTS.md may need to recompute)
    * a change under queue/ -> `{:queue_changed}` on `"queue"`

  Each tree gets its own debounce timer so a burst of activity in one does
  not delay or coalesce with the other. `mounts_changed` shares the mounts
  tree's single debounce timer rather than getting a separate one: every
  event seen during the window is classified as it arrives, and on flush
  the handler emits `icm_changed` unconditionally plus `mounts_changed` only
  if something discovery-relevant was seen — so a manifest touch inside a
  content burst still gets both events, exactly once, together. Events
  carry no payload by design — consumers refetch (cheap to rebuild, and the
  fs events themselves are noisy).

  FSEvents (the macOS backend — and watcher backends generally) only
  reports changes under a path that already existed when the watch stream
  was created; a directory created afterward is invisible to it even once
  populated. `mounts/` is not guaranteed to exist yet at workspace-open
  time (that's only true starting the template migration in A-T8), so
  `init/1` creates both watched directories up front rather than assuming
  the caller already has.

  Started under `Valea.Workspace.Runtime` — it lives and dies with the open
  workspace, same as the audit writer and agent session supervisor.
  """
  use GenServer

  @debounce_ms 200

  def start_link({mounts_path, queue_path}),
    do: GenServer.start_link(__MODULE__, {mounts_path, queue_path}, name: __MODULE__)

  @impl true
  def init({mounts_path, queue_path}) do
    File.mkdir_p!(mounts_path)
    File.mkdir_p!(queue_path)

    {:ok, watcher} = FileSystem.start_link(dirs: [mounts_path, queue_path])
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
       mounts_path: canonical(mounts_path),
       queue_path: canonical(queue_path),
       mounts_timer: nil,
       mounts_discovery_pending: false,
       queue_timer: nil
     }}
  end

  @impl true
  def handle_info({:file_event, _pid, {path, _events}}, state) do
    cond do
      under?(path, state.queue_path) -> {:noreply, arm(:queue_timer, :flush_queue, state)}
      under?(path, state.mounts_path) -> {:noreply, note_mounts_event(path, state)}
      true -> {:noreply, state}
    end
  end

  def handle_info({:file_event, _pid, :stop}, state), do: {:noreply, state}

  def handle_info(:flush_mounts, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "icm", {:icm_changed})

    if state.mounts_discovery_pending do
      Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
    end

    {:noreply, %{state | mounts_timer: nil, mounts_discovery_pending: false}}
  end

  def handle_info(:flush_queue, state) do
    Phoenix.PubSub.broadcast(Valea.PubSub, "queue", {:queue_changed})
    {:noreply, %{state | queue_timer: nil}}
  end

  # A bare touch on `mounts_path` itself (no sub-path — e.g. the one-time
  # directory-creation event from `init/1`'s own `mkdir_p!`, or a parent
  # mtime bump FSEvents reports alongside a deeper change) names no page or
  # mount and is a pure no-op: nothing to refetch, nothing to reclassify.
  # Any deeper change under mounts/ still lands its own event with its own
  # non-empty segment list, so this never drops real signal.
  defp note_mounts_event(path, state) do
    case relative_segments(path, state.mounts_path) do
      [] ->
        state

      segments ->
        state = arm(:mounts_timer, :flush_mounts, state)

        if discovery_relevant?(segments) do
          %{state | mounts_discovery_pending: true}
        else
          state
        end
    end
  end

  # A change to the mount SET, not just a mount's content: either a
  # top-level `mounts/<name>` entry itself (dir added/removed) or its
  # `icm.yaml` manifest (name/description, and the file whose mere
  # presence marks a mount as non-degraded). Anything deeper — a page or
  # folder inside the mount — is content-only.
  defp discovery_relevant?([_name]), do: true
  defp discovery_relevant?([_name, "icm.yaml"]), do: true
  defp discovery_relevant?(_other), do: false

  defp relative_segments(path, root) do
    cond do
      path == root ->
        []

      String.starts_with?(path, root <> "/") ->
        path |> String.replace_prefix(root <> "/", "") |> Path.split()

      true ->
        []
    end
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
