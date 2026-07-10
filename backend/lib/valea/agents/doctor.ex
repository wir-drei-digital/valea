defmodule Valea.Agents.Doctor do
  @moduledoc """
  Preflight probe for the agent harness. When starting a session fails
  preflight (adapter missing, not logged in, ...) the UI routes to a guided
  doctor screen; this module is the backend side of that screen — three
  independent checks, each with a status and a copyable remedy.

  Checks (spec §Doctor):

    1. `node` — Node 22+ on PATH.
    2. `adapter` — the configured ACP adapter executable resolves and
       answers `--version`.
    3. `auth` — the adapter reports it is logged in (`--cli auth status`).

  A check is `"unknown"` (never `"failed"`) when the probe itself could not
  run at all (adapter unresolved, process spawn error, timeout) — an honest
  "we don't know" rather than a false claim that auth is broken. `"failed"`
  means the probe ran and reported a problem.
  """

  alias Valea.Agents.CommandSpec
  alias Valea.Harnesses.ClaudeCode

  @type check :: %{String.t() => String.t() | nil}

  @timeout_ms 5_000

  @node_remedy "Install Node 22 or newer (https://nodejs.org)"
  @adapter_remedy "npm install -g @agentclientprotocol/claude-agent-acp"
  @auth_remedy "claude-agent-acp --cli auth login --claudeai"

  @doc "Runs all three checks against the real machine. The public entry point."
  @spec run() :: {:ok, %{checks: [check], ok: boolean}}
  def run, do: run(%{})

  @doc """
  Same as `run/0`, plus a TEST-ONLY override map so checks don't depend on
  the real machine:

    * `:node` — executable path to use instead of
      `System.find_executable("node")`, for testing version parsing with a
      fake `node` script.

  Not part of the public contract — `run/0` is the supported entry point.
  """
  @spec run(map()) :: {:ok, %{checks: [check], ok: boolean}}
  def run(opts) when is_map(opts) do
    checks = [
      node_check(opts[:node]),
      adapter_check(),
      auth_check()
    ]

    {:ok, %{checks: checks, ok: Enum.all?(checks, &(&1["status"] == "ok"))}}
  end

  # -- node ----------------------------------------------------------------

  defp node_check(override) do
    case override || System.find_executable("node") do
      nil ->
        failed("node", "node was not found on PATH.", @node_remedy)

      exe ->
        case run_cmd(exe, ["--version"]) do
          {:ok, {output, 0}} ->
            node_version_result(output)

          {:ok, {output, code}} ->
            failed(
              "node",
              "`node --version` exited #{code}: #{String.trim(output)}",
              @node_remedy
            )

          {:error, :timeout} ->
            failed("node", "`node --version` did not respond within 5s.", @node_remedy)

          {:error, reason} ->
            failed("node", "`node --version` could not be run: #{inspect(reason)}", @node_remedy)
        end
    end
  end

  defp node_version_result(output) do
    trimmed = String.trim(output)

    case Regex.run(~r/^v?(\d+)(?:\.|$)/, trimmed) do
      [_, major] ->
        if String.to_integer(major) >= 22 do
          ok("node", "node #{trimmed}")
        else
          failed("node", "node #{trimmed} is older than the required 22.", @node_remedy)
        end

      nil ->
        failed(
          "node",
          "Could not parse a version from `node --version` output: #{inspect(trimmed)}",
          @node_remedy
        )
    end
  end

  # -- adapter ---------------------------------------------------------------

  defp adapter_check do
    case ClaudeCode.acp_command(%{}) do
      {:ok, %CommandSpec{cmd: cmd}} ->
        case run_cmd(cmd, ["--version"]) do
          {:ok, {output, 0}} ->
            ok("adapter", "#{cmd} --version -> #{String.trim(output)}")

          {:ok, {output, code}} ->
            failed(
              "adapter",
              "#{cmd} --version exited #{code}: #{String.trim(output)}",
              @adapter_remedy
            )

          {:error, :timeout} ->
            failed("adapter", "#{cmd} --version did not respond within 5s.", @adapter_remedy)

          {:error, reason} ->
            failed(
              "adapter",
              "#{cmd} --version could not be run: #{inspect(reason)}",
              @adapter_remedy
            )
        end

      {:error, :harness_unavailable} ->
        failed(
          "adapter",
          "No adapter executable is configured or resolvable on PATH.",
          @adapter_remedy
        )
    end
  end

  # -- auth --------------------------------------------------------------

  defp auth_check do
    case ClaudeCode.acp_command(%{}) do
      {:ok, %CommandSpec{cmd: cmd}} ->
        case run_cmd(cmd, ["--cli", "auth", "status"]) do
          {:ok, {_output, 0}} ->
            ok("auth", "#{cmd} --cli auth status -> logged in")

          {:ok, {output, code}} ->
            failed(
              "auth",
              "#{cmd} --cli auth status exited #{code}: #{String.trim(output)}",
              @auth_remedy
            )

          {:error, :timeout} ->
            unknown(
              "auth",
              "#{cmd} --cli auth status did not respond within 5s; auth state could not be determined."
            )

          {:error, reason} ->
            unknown(
              "auth",
              "#{cmd} --cli auth status could not be run (#{inspect(reason)}); " <>
                "auth state could not be determined."
            )
        end

      {:error, :harness_unavailable} ->
        unknown(
          "auth",
          "No adapter executable is configured or resolvable on PATH; " <>
            "auth state could not be determined."
        )
    end
  end

  # -- shared ------------------------------------------------------------

  # Runs cmd/args via erlexec (not System.cmd/Port) so a timeout can
  # GUARANTEE the OS process tree is gone, not just the BEAM-side handle.
  # `{:group, 0}` + `:kill_group` puts the child in its own process group;
  # on timeout `:exec.stop/1` kills that whole group and — per erlexec —
  # blocks until it has actually exited, so no orphaned `sleep`/shell
  # descendants survive a hung adapter across repeated doctor runs. This is
  # the same pattern `Valea.Agents.ProcessRuntime` uses for long-lived
  # runtime subprocesses.
  defp run_cmd(cmd, args, timeout_ms \\ @timeout_ms) do
    if File.exists?(cmd) do
      exec_and_await(cmd, args, timeout_ms)
    else
      {:error, :enoent}
    end
  end

  defp exec_and_await(cmd, args, timeout_ms) do
    run_opts = [:monitor, :stdout, :stderr, {:group, 0}, :kill_group]

    case :exec.run([cmd | args], run_opts) do
      {:ok, _pid, os_pid} -> await_exit(os_pid, timeout_ms, [])
      {:error, reason} -> {:error, reason}
    end
  end

  defp await_exit(os_pid, timeout_ms, acc) do
    receive do
      {:stdout, ^os_pid, data} ->
        await_exit(os_pid, timeout_ms, [data | acc])

      {:stderr, ^os_pid, data} ->
        await_exit(os_pid, timeout_ms, [data | acc])

      {:DOWN, ^os_pid, :process, _pid, reason} ->
        output = acc |> Enum.reverse() |> IO.iodata_to_binary()
        {:ok, {output, exit_code(reason)}}
    after
      timeout_ms ->
        # Synchronous: does not return until the whole process group has
        # exited, so the OS process tree is confirmed gone before this
        # function (and therefore run/1) returns to the caller.
        :exec.stop(os_pid)
        {:error, :timeout}
    end
  end

  defp exit_code(:normal), do: 0
  defp exit_code({:exit_status, status}), do: status |> :exec.status() |> status_to_code()
  defp exit_code(_signal_or_other), do: 1

  defp status_to_code({:status, code}), do: code
  defp status_to_code({:signal, _sig, _core}), do: 1

  defp ok(id, detail), do: %{"id" => id, "status" => "ok", "detail" => detail, "remedy" => nil}

  defp failed(id, detail, remedy),
    do: %{"id" => id, "status" => "failed", "detail" => detail, "remedy" => remedy}

  defp unknown(id, detail),
    do: %{"id" => id, "status" => "unknown", "detail" => detail, "remedy" => nil}
end
