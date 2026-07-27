defmodule Valea.Agents.ProcessRuntime.PortShim do
  @moduledoc """
  The WINDOWS half of the `Valea.Agents.ProcessAdapter` split (windows-support
  spec B1/B2): an Erlang Port onto the `valea-spawn` shim.

  A Port alone cannot host an agent. It carries ONE input stream (so the
  agent's stderr would land in the NDJSON decoder), and closing it abandons
  the OS process on Windows (so a stuck agent would outlive its session). The
  shim supplies exactly those two things and nothing else:

    * the child's stderr goes to a FILE named by `VALEA_SPAWN_STDERR_FILE`,
      which this adapter reads the tail of and emits as ONE
      `{:runtime_stderr, tail}` when the process exits. Coarser than unix's
      live stream — the documented platform difference, not a bug;
    * the child runs in a Job Object with `KILL_ON_JOB_CLOSE`, and EOF on the
      shim's stdin is the teardown signal. So `stop/1` is `Port.close/1` and
      nothing else: no taskkill, no pid races, no orphaned grandchildren.

  Everything here is platform-neutral Port code — only its SELECTION is
  Windows-bound — which is what lets the adapter be driven against a fake
  shim on any host (`port_shim_test.exs`); the real shim's own contract is
  proven by the Rust suite in `desktop/src-tauri`.

  ## Failing loudly

  The shim's own exit codes (64/65/66/101) all mean "no child ever ran". Two
  of them are made unreachable here rather than diagnosed later: this adapter
  always sets `VALEA_SPAWN_STDERR_FILE` and creates its parent directory (64,
  65), and it refuses up front to hand a `.cmd`/`.bat` target an argument
  containing `"` (64), which the shim cannot quote for `cmd.exe`. A missing
  shim, a missing `stderr_path` and a missing executable all fail
  `start/2` — the session never comes up half-alive, and the doctor sees the
  reason (spec B2: never a silent fallback to Port-only).

  What is left — 66 (target unspawnable) and 101 (shim panic) — cannot be
  told apart from a child that chose the same exit code; the shim says so
  explicitly. But when the shim returns one of them, nothing was produced:
  no stdout byte, an empty stderr file. On that evidence the shim-level
  reading is the only consistent one, so an extra `{:runtime_stderr, …}` line
  names it before the exit code goes out. The code itself is always relayed
  unchanged.
  """

  @behaviour Valea.Agents.ProcessAdapter

  @start_timeout_ms 5_000
  @stderr_tail_bytes 64 * 1024

  # Shim-level exits worth annotating. 120 (stdin-EOF teardown) is deliberately
  # absent: it is the NORMAL `stop/1` path, and on that path we close the port
  # and report `{:runtime_exit, nil}` ourselves, so seeing 120 here at all
  # would mean a race with a concurrent exit — not something to shout about.
  @shim_exits %{
    64 => "contract violation (no command, no stderr file, or an unquotable batch argument)",
    65 => "the stderr file could not be created",
    66 => "the target could not be spawned (missing, not executable, or a bad COMSPEC)",
    101 => "shim-internal panic — please report this"
  }

  @impl true
  @spec start(map(), pid()) :: {:ok, map()} | {:error, String.t()}
  def start(%{cmd: cmd} = spec, owner) when is_pid(owner) do
    args = Map.get(spec, :args, [])

    with {:ok, shim} <- shim_path(),
         {:ok, stderr_path} <- stderr_path(spec),
         :ok <- check_cmd(cmd),
         :ok <- check_batch_args(cmd, args),
         :ok <- prepare_stderr_dir(stderr_path) do
      do_start(shim, spec, stderr_path, owner)
    end
  end

  # Set by the desktop shell when it spawns the sidecar (spec B2). Absent or
  # stale is a broken install, not a reason to spawn something unsupervised.
  defp shim_path do
    case System.get_env("VALEA_SPAWN_SHIM") do
      nil ->
        {:error, "spawn shim missing — reinstall Valea (windows spec B2)"}

      path ->
        if File.exists?(path),
          do: {:ok, path},
          else: {:error, "spawn shim missing at #{path} (windows spec B2)"}
    end
  end

  # Supplied per spawn by the caller — `SessionServer` puts it beside the
  # session transcript, the doctor in tmp. Never defaulted: a stderr stream
  # silently going nowhere is how agent misconfiguration turns into an
  # unexplainable hang.
  defp stderr_path(spec) do
    case Map.get(spec, :stderr_path) do
      path when is_binary(path) and path != "" -> {:ok, path}
      _ -> {:error, "stderr path missing (windows spec B2)"}
    end
  end

  defp check_cmd(cmd) do
    cond do
      !is_binary(cmd) or cmd == "" -> {:error, "no executable configured"}
      !File.exists?(cmd) -> {:error, "executable not found: #{cmd}"}
      true -> :ok
    end
  end

  # The shim routes .cmd/.bat targets through COMSPEC and owns the quoting,
  # but an embedded `"` is not quotable for cmd.exe — it answers exit 64. Ask
  # here instead, where the answer can name the argument.
  defp check_batch_args(cmd, args) do
    if batch?(cmd) and Enum.any?(args, &String.contains?(&1, "\"")) do
      {:error,
       "a .cmd/.bat target cannot take an argument containing a double quote (windows spec B2)"}
    else
      :ok
    end
  end

  defp batch?(cmd) do
    String.downcase(Path.extname(cmd)) in [".cmd", ".bat"]
  end

  # The shim creates the FILE (pre-spawn, so a bad path is an exit code and
  # never a hang); the directory is ours.
  defp prepare_stderr_dir(stderr_path) do
    case File.mkdir_p(Path.dirname(stderr_path)) do
      :ok -> :ok
      {:error, reason} -> {:error, "stderr directory unusable: #{:file.format_error(reason)}"}
    end
  end

  defp do_start(shim, spec, stderr_path, owner) do
    relay = spawn_relay(shim, spec, stderr_path, owner)

    receive do
      {:relay_started, ^relay, os_pid} ->
        {:ok, %{os_pid: os_pid, relay_pid: relay, stderr_path: stderr_path}}

      {:relay_failed, ^relay, reason} ->
        {:error, inspect(reason)}
    after
      @start_timeout_ms ->
        Process.exit(relay, :kill)
        {:error, "subprocess start timed out"}
    end
  end

  defp spawn_relay(shim, spec, stderr_path, owner) do
    parent = self()

    spawn(fn ->
      # The Port is linked to THIS process, so the shim's stdin closes — and
      # the Job takes the tree with it — the moment the relay dies. Monitoring
      # the owner extends that one level up: `SessionServer` stops us from
      # `terminate/2`, but a brutal kill has no `terminate/2`. On unix erlexec
      # reaps children whose owner vanished; this monitor is how the Port
      # adapter earns the same promise.
      Process.monitor(owner)

      # Trapping turns the port's own exit into a message instead of taking
      # the relay down with it. A port that dies WITHOUT delivering
      # `:exit_status` (driver failure, an emulator-side close) would
      # otherwise kill the relay silently and leave the owner waiting forever
      # for a `:runtime_exit` that can no longer come. `Process.exit(relay,
      # :kill)` on the start-timeout path is untrappable, so that stays exact.
      Process.flag(:trap_exit, true)

      case open_port(shim, spec, stderr_path) do
        {:ok, port} ->
          send(parent, {:relay_started, self(), os_pid(port)})
          ctx = %{owner: owner, stderr_path: stderr_path, cmd: spec.cmd}
          relay_loop(port, ctx, false)

        {:error, reason} ->
          send(parent, {:relay_failed, self(), reason})
      end
    end)
  end

  defp open_port(shim, spec, stderr_path) do
    # `spec.stdin` is deliberately not consulted: a Port cannot half-close its
    # stdin, and for the shim EOF there means "kill the tree" (exit 120). A
    # `:closed` probe therefore runs with an open, never-written stdin here —
    # see `Valea.Agents.ProcessAdapter` for why that is acceptable and what a
    # probe that actually reads stdin would need instead.
    opts = [
      :binary,
      :exit_status,
      # Windows-only effect (no console window for the shim); ignored elsewhere.
      :hide,
      {:args, [spec.cmd | Map.get(spec, :args, [])]},
      {:cd, spec.cd},
      {:env, env_charlists(spec.env, stderr_path)}
    ]

    {:ok, Port.open({:spawn_executable, shim}, opts)}
  rescue
    # A missing/unreadable shim binary (`:enoent`, `:eacces`) or a bad option
    # arrives as an exception; the caller wants an `{:error, reason}`.
    e in [ArgumentError, ErlangError] -> {:error, Exception.message(e)}
  end

  # Merged into the inherited environment, like erlexec's `{:env, …}` on unix
  # — `Valea.Agents.Env.minimal/0` decides what Valea CONTRIBUTES. The stderr
  # file is put last on purpose: it is the adapter's, not the caller's.
  defp env_charlists(env, stderr_path) do
    env
    |> Map.put("VALEA_SPAWN_STDERR_FILE", stderr_path)
    |> Enum.map(fn {key, value} -> {native_charlist(key), native_charlist(value)} end)
  end

  # `open_port`'s `{:env, …}` takes CHARLISTS (a binary is rejected outright:
  # "invalid option in list") and erts converts them with the emulator's file
  # name encoding. That encoding is not universal, and getting it wrong is not
  # a cosmetic bug — measured on both settings:
  #
  #   +fnu (macOS, Windows): a charlist of CODEPOINTS is encoded correctly;
  #                          feeding it UTF-8 bytes instead double-encodes.
  #   +fnl (a latin1 host):  a codepoint above 255 cannot be represented and
  #                          `Port.open` raises badarg — a user whose
  #                          USERPROFILE or PATH is not Latin-1 could not
  #                          spawn an agent at all; UTF-8 BYTES pass through
  #                          verbatim, which is what a POSIX environment
  #                          wants anyway.
  #
  # So the conversion asks which encoding erts will actually apply, instead of
  # assuming one.
  defp native_charlist(value) do
    case :file.native_name_encoding() do
      :latin1 -> :binary.bin_to_list(value)
      _utf8 -> String.to_charlist(value)
    end
  end

  defp relay_loop(port, ctx, saw_output?) do
    receive do
      {^port, {:data, data}} ->
        send(ctx.owner, {:runtime_output, data})
        relay_loop(port, ctx, true)

      {^port, {:exit_status, code}} ->
        tail_bytes = emit_stderr_tail(ctx)
        maybe_explain_shim_exit(code, saw_output?, tail_bytes, ctx)
        send(ctx.owner, {:runtime_exit, code})

      {:write, data} ->
        command(port, IO.iodata_to_binary(data))
        relay_loop(port, ctx, saw_output?)

      :stop ->
        # Closing the port is the ENTIRE teardown: the shim sees stdin EOF and
        # closes its Job handle, which kills the tree. The exit code that
        # follows (120) never reaches us — the port is gone — so the owner
        # gets `nil`, matching unix's "killed, code unknown".
        close_port(port)
        emit_stderr_tail(ctx)
        send(ctx.owner, {:runtime_exit, nil})

      # The owner is the ONLY thing this relay monitors (see spawn_relay/4).
      {:DOWN, _ref, :process, _pid, _reason} ->
        close_port(port)

      # The port died without an `:exit_status` (it is always delivered
      # first, so reaching here means the port itself failed). Report the
      # exit we cannot name rather than dying quietly and hanging the owner.
      {:EXIT, ^port, _reason} ->
        emit_stderr_tail(ctx)
        send(ctx.owner, {:runtime_exit, nil})
    end
  end

  defp maybe_explain_shim_exit(code, saw_output?, tail_bytes, ctx) do
    reason = Map.get(@shim_exits, code)

    if reason && not saw_output? && tail_bytes == 0 do
      send(
        ctx.owner,
        {:runtime_stderr,
         "valea-spawn exited #{code}: #{reason}. No agent process was started " <>
           "(target: #{ctx.cmd}, stderr file: #{ctx.stderr_path}) — windows spec B2.\n"}
      )
    end

    :ok
  end

  # Best-effort tail: the shim caps the file at 1 MiB, we forward at most the
  # last 64 KiB of it. Returns the byte count so the caller can tell "the
  # child said nothing" from "the child explained itself".
  defp emit_stderr_tail(ctx) do
    with {:ok, %File.Stat{size: size}} when size > 0 <- File.stat(ctx.stderr_path),
         offset = max(size - @stderr_tail_bytes, 0),
         {:ok, io} <- :file.open(ctx.stderr_path, [:read, :binary]) do
      tail =
        case :file.pread(io, offset, size - offset) do
          {:ok, data} -> data
          _ -> ""
        end

      :file.close(io)
      if tail != "", do: send(ctx.owner, {:runtime_stderr, tail})
      byte_size(tail)
    else
      _ -> 0
    end
  end

  defp os_pid(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, pid} -> pid
      _ -> nil
    end
  end

  defp command(port, data) do
    Port.command(port, data)
    :ok
  rescue
    # The child exited a moment ago and its `:exit_status` is already in our
    # mailbox; dropping the write is right — the next loop iteration reports
    # the exit.
    ArgumentError -> :ok
  end

  defp close_port(port) do
    Port.close(port)
    :ok
  rescue
    # Same race, other direction: the port closed itself between the owner
    # calling `stop/1` and us handling it.
    ArgumentError -> :ok
  end

  @impl true
  @spec write(map(), iodata()) :: :ok
  def write(%{relay_pid: relay}, data) do
    send(relay, {:write, data})
    :ok
  end

  @impl true
  @spec stop(map()) :: :ok
  def stop(%{relay_pid: relay}) do
    send(relay, :stop)
    :ok
  end
end
