defmodule Valea.Agents.ProcessRuntime do
  @moduledoc """
  Spawns an OS subprocess with plain stdio pipes via erlexec and relays its
  output to an owner process as messages:

      {:runtime_output, binary}   # stdout — the NDJSON stream
      {:runtime_stderr, binary}   # stderr — NEVER fed to the JSON decoder
      {:runtime_exit, code | nil} # nil for signal kills

  Vendored pattern from legend's Legend.Runtimes.LocalPty (pipes mode).
  `stop/1` kills the whole process group so adapter children never orphan.
  """

  @start_timeout_ms 5_000

  @spec start(map(), pid()) :: {:ok, map()} | {:error, String.t()}
  def start(%{cmd: cmd} = spec, owner) when is_pid(owner) do
    cond do
      !is_binary(cmd) or cmd == "" -> {:error, "no executable configured"}
      !File.exists?(cmd) -> {:error, "executable not found: #{cmd}"}
      true -> do_start(spec, owner)
    end
  end

  defp do_start(spec, owner) do
    relay = spawn_relay(spec, owner)

    receive do
      {:relay_started, ^relay, os_pid} -> {:ok, %{os_pid: os_pid, exec_pid: relay}}
      {:relay_failed, ^relay, reason} -> {:error, inspect(reason)}
    after
      @start_timeout_ms ->
        Process.exit(relay, :kill)
        {:error, "subprocess start timed out"}
    end
  end

  defp spawn_relay(spec, owner) do
    parent = self()

    spawn(fn ->
      argv = [spec.cmd | spec.args]

      run_opts = [
        :stdin,
        {:stdout, self()},
        {:stderr, self()},
        {:env, Map.to_list(spec.env)},
        {:cd, spec.cd},
        {:group, 0},
        :kill_group,
        :monitor,
        {:kill_timeout, 5}
      ]

      case :exec.run(argv, run_opts) do
        {:ok, _pid, os_pid} ->
          send(parent, {:relay_started, self(), os_pid})
          relay_loop(os_pid, owner)

        {:error, reason} ->
          send(parent, {:relay_failed, self(), reason})
      end
    end)
  end

  defp relay_loop(os_pid, owner) do
    receive do
      {:stdout, ^os_pid, data} ->
        send(owner, {:runtime_output, data})
        relay_loop(os_pid, owner)

      {:stderr, ^os_pid, data} ->
        send(owner, {:runtime_stderr, data})
        relay_loop(os_pid, owner)

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        send(owner, {:runtime_exit, decode_exit(reason)})

      {:write, data} ->
        :exec.send(os_pid, IO.iodata_to_binary(data))
        relay_loop(os_pid, owner)

      :stop ->
        :exec.stop(os_pid)
        relay_loop(os_pid, owner)
    end
  end

  @spec write(map(), iodata()) :: :ok
  def write(%{exec_pid: relay}, data) do
    send(relay, {:write, data})
    :ok
  end

  @spec stop(map()) :: :ok
  def stop(%{exec_pid: relay}) do
    send(relay, :stop)
    :ok
  end

  defp decode_exit(:normal), do: 0
  defp decode_exit({:exit_status, status}), do: :exec.status(status) |> exit_code()
  defp decode_exit(_), do: nil

  defp exit_code({:status, code}), do: code
  defp exit_code({:signal, _sig, _core}), do: nil
end
