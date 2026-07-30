defmodule Valea.Schedules.CommandRun do
  @moduledoc """
  One running `kind: "command"` fire: a supervised process that owns the
  subprocess, accumulates its output, enforces the timeout, and reports the
  outcome back to `Valea.Schedules.Scheduler`.

  Registered in `Valea.Schedules.RunRegistry` under `{icm_id, schedule_id}`,
  which does double duty: it makes "one run of this schedule at a time"
  enforceable at start (`{:error, {:already_started, _}}`) and *observable*
  afterwards, so the scheduler derives liveness from the world instead of
  remembering it.

  ## The containment contract, in full

  There is no sandbox — a scheduled command runs with the user's full
  authority, which is exactly why registering one is always-ask (spec §Consent
  & containment, accepted risk #1). What this process does provide is the
  complete list:

    * **exec-style spawn** — `command` + `args`, never a shell string, so
      nothing in the payload is interpolated by a shell;
    * **executable resolution like a terminal's** — absolute path as given,
      a path with a separator resolved against the ICM root, a bare name
      looked up on `PATH`;
    * **cwd = the ICM root**;
    * **`Valea.Agents.Env.minimal/0`** — the platform allowlist Valea
      contributes (never a sealed environment: the adapter MERGES into what
      the backend inherited, see `Valea.Agents.ProcessAdapter`);
    * **a 10-minute timeout** → `timed out`, subprocess and its whole process
      group killed;
    * **output capped at 256 KiB** (stdout and stderr interleaved as they
      arrive), with one `[output capped]` marker appended when the cap bites;
    * **the run record** — the fire, the full command line in the audit, and
      the outcome.

  ## Outcome tokens

  `completed` (exit 0), `failed` (any other code, `nil` included — a signal
  kill is a failure), `timed out`. `interrupted` is written by the
  scheduler's shutdown path, not here: this process is being terminated at
  that moment and cannot be the one to record it.

  Detail never rides the outcome token — the notice feed matches those by
  exact equality (`Valea.Schedules.Store.Run`). Exit codes and stderr go in
  `output`.
  """
  use GenServer, restart: :temporary

  alias Valea.Agents.ProcessRuntime

  @output_cap 262_144
  @timeout_ms 600_000
  @capped_marker "\n[output capped]"

  @doc """
  Starts a run for `%{mount:, entry:, meta:, owner:}`. Named through the
  Registry, so a second start for the same `{icm_id, schedule_id}` is refused
  rather than doubled.
  """
  def start_link(%{meta: meta} = args) do
    GenServer.start_link(__MODULE__, args, name: via(meta.icm_id, meta.schedule_id))
  end

  @doc "The Registry name for a schedule's run — also its liveness key."
  def via(icm_id, schedule_id),
    do: {:via, Registry, {Valea.Schedules.RunRegistry, {icm_id, schedule_id}}}

  @impl true
  def init(%{mount: mount, entry: entry, meta: meta, owner: owner} = args) do
    # Trapped so `terminate/2` runs on a workspace close and can stop the
    # subprocess (which erlexec would otherwise leave orphaned).
    Process.flag(:trap_exit, true)

    case spawn_command(mount, entry, meta) do
      {:ok, handle} ->
        {:ok,
         %{
           handle: handle,
           meta: meta,
           owner: owner,
           output: "",
           capped: false,
           started_ms: System.monotonic_time(:millisecond),
           # `timeout_ms` is a test seam (the suite cannot wait ten minutes);
           # production always takes the default.
           timer: Process.send_after(self(), :timeout, Map.get(args, :timeout_ms, @timeout_ms)),
           reported: false
         }}

      {:error, reason} ->
        # `:stop` in `init/1` surfaces to `DynamicSupervisor.start_child/2` as
        # `{:error, reason}`, which the runner turns into a `failed` run
        # record — a spawn that never happened must not look like a run.
        {:stop, {:spawn_failed, reason}}
    end
  end

  @impl true
  def handle_info({:runtime_output, data}, state), do: {:noreply, accumulate(state, data)}

  @impl true
  def handle_info({:runtime_stderr, data}, state), do: {:noreply, accumulate(state, data)}

  @impl true
  def handle_info({:runtime_exit, 0}, state), do: finish(state, "completed")

  @impl true
  def handle_info({:runtime_exit, code}, state) do
    finish(state, "failed", "exit status #{inspect(code)}")
  end

  @impl true
  def handle_info(:timeout, state) do
    ProcessRuntime.stop(state.handle)
    finish(state, "timed out", "killed on timeout")
  end

  @impl true
  def handle_info(_ignored, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    # Workspace close / switch: stop the subprocess and its process group. The
    # `interrupted` run record is the scheduler's shutdown path (it terminates
    # BEFORE this process, while the Registry is still readable).
    if is_map(state) and Map.has_key?(state, :handle), do: ProcessRuntime.stop(state.handle)
    :ok
  catch
    _kind, _reason -> :ok
  end

  # -- spawn -------------------------------------------------------------------

  defp spawn_command(mount, entry, meta) do
    %{command: command, args: args} = entry.payload

    case resolve_executable(command, mount.root) do
      {:ok, cmd} ->
        ProcessRuntime.start(
          %{
            cmd: cmd,
            args: args,
            env: Valea.Agents.Env.minimal(),
            cd: mount.root,
            # A scheduled command has nobody to type at it; an immediate EOF is
            # what makes a program that reads stdin exit instead of hanging
            # until the timeout.
            stdin: :closed,
            stderr_path: stderr_path(meta)
          },
          self()
        )

      {:error, reason} ->
        {:error, reason}
    end
  end

  # "Resolves like a terminal would" (spec §Payload kinds). Absolute stays
  # absolute; anything with a separator is ICM-root-relative (so
  # `scripts/sync.sh` means this ICM's script); a bare name is a `PATH`
  # lookup. Deliberately NOT contained to the ICM root: a command payload runs
  # with the user's authority by design, and `/usr/bin/rsync` is the ordinary
  # case, not an escape.
  defp resolve_executable(command, icm_root) do
    cond do
      Path.type(command) == :absolute ->
        {:ok, command}

      String.contains?(command, "/") or String.contains?(command, "\\") ->
        {:ok, Path.expand(command, icm_root)}

      true ->
        find_on_path(command)
    end
  end

  defp find_on_path(command) do
    case System.find_executable(command) do
      nil -> {:error, "executable not found on PATH: #{command}"}
      path -> {:ok, path}
    end
  end

  # Where the windows spawn shim writes the child's stderr (windows-support
  # spec B2; `Exec` ignores it). Under the workspace's own log tree, one file
  # per run.
  defp stderr_path(meta) do
    path =
      Path.join([
        meta.workspace_root,
        "logs",
        "schedules",
        "#{meta.run_id}.stderr.log"
      ])

    File.mkdir_p!(Path.dirname(path))
    path
  end

  # -- output ------------------------------------------------------------------

  defp accumulate(%{capped: true} = state, _data), do: state

  defp accumulate(state, data) do
    combined = state.output <> data

    if byte_size(combined) >= @output_cap do
      %{state | output: binary_part(combined, 0, @output_cap) <> @capped_marker, capped: true}
    else
      %{state | output: combined}
    end
  end

  # -- completion --------------------------------------------------------------

  defp finish(state, outcome, detail \\ nil)

  defp finish(%{reported: true} = state, _outcome, _detail), do: {:stop, :normal, state}

  defp finish(state, outcome, detail) do
    Process.cancel_timer(state.timer)
    duration = System.monotonic_time(:millisecond) - state.started_ms
    output = with_detail(state.output, detail)

    send(report_to(state), {:run_finished, state.meta.run_id, outcome, duration, output})

    {:stop, :normal, %{state | reported: true}}
  end

  # The REGISTERED scheduler, not the pid that started this run — those differ
  # after a scheduler crash. `Valea.Schedules.Supervisor` is `:one_for_one`, so a
  # crashed scheduler is replaced while this process and its subprocess keep
  # running; a captured pid would then be a corpse, `send/2` to it would
  # silently succeed, and the outcome would vanish (leaving a `running` row for
  # the next boot pass to mark `interrupted` — evidence destroyed for no reason).
  #
  # Falls back to the owner when no scheduler is registered, which is how a
  # runner started outside the supervision tree (the command-run tests) gets its
  # report.
  defp report_to(state) do
    Process.whereis(Valea.Schedules.Scheduler) || state.owner
  end

  defp with_detail(output, nil), do: output
  defp with_detail("", detail), do: detail
  defp with_detail(output, detail), do: output <> "\n" <> detail
end
