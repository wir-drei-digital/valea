defmodule Valea.Git.Cli do
  @moduledoc """
  Runs git through `Valea.Agents.ProcessRuntime` — never `System.cmd` — so a
  timeout guarantees the OS process tree is gone (erlexec's process-group
  kill on unix, the spawn shim's Job Object on windows), not merely the
  BEAM-side handle. A git that hangs on a credential or ssh-passphrase prompt
  is the ordinary case this protects against, and it is why stdin is closed
  and `GIT_TERMINAL_PROMPT=0` is contributed: git must never wait for a human
  who isn't there.

  Each invocation runs in its OWN task because the runtime's messages are
  untagged and addressed to whoever called `start/2` — the same rationale as
  `Valea.Agents.Doctor`: with a shared mailbox, a straggler from a timed-out
  call is collected as the NEXT call's result, so a `git status` could return
  a `git push`'s exit code. An isolated mailbox makes that structurally
  impossible and needs no draining, since it dies with the task.

  stdout and stderr are interleaved into one `output` in arrival order:
  callers here are error-reporting, not parsing a stream, and git puts the
  interesting part (why a push was rejected) on stderr.
  """

  alias Valea.Agents.ProcessRuntime

  require Logger

  @callback run(String.t(), [String.t()], keyword()) ::
              {:ok, %{output: String.t(), exit: non_neg_integer()}}
              | {:error, :timeout | :git_not_found}

  @behaviour __MODULE__

  @default_timeout_ms 15_000
  # How long a killed git gets to confirm it is gone. Must CLEAR erlexec's own
  # escalation window — `Exec` spawns with `{:kill_timeout, 5}`, i.e. SIGTERM
  # then SIGKILL five seconds later — so a shorter grace could expire in the
  # same instant as the kill it is waiting for (see `Valea.Agents.Doctor`).
  @kill_grace_ms 12_000
  # Slack above the call's own bound, so the outer task wait is a backstop for
  # a wedged runtime, never the thing that decides a git call's fate.
  @await_margin_ms 5_000
  @output_cap 262_144

  @doc "Same as `run/3` with default options."
  @spec run(String.t(), [String.t()]) ::
          {:ok, %{output: String.t(), exit: non_neg_integer()}}
          | {:error, :timeout | :git_not_found}
  def run(repo_root, args), do: run(repo_root, args, [])

  @doc """
  Runs `git -C repo_root <args>` and returns its interleaved output plus exit
  code. `opts[:timeout_ms]` defaults to #{@default_timeout_ms}; network verbs
  pass a longer one.
  """
  @impl true
  @spec run(String.t(), [String.t()], keyword()) ::
          {:ok, %{output: String.t(), exit: non_neg_integer()}}
          | {:error, :timeout | :git_not_found}
  def run(repo_root, args, opts) do
    case System.find_executable("git") do
      nil ->
        {:error, :git_not_found}

      git ->
        timeout_ms = Keyword.get(opts, :timeout_ms, @default_timeout_ms)
        task = Task.async(fn -> spawn_and_await(git, repo_root, args, timeout_ms) end)

        # `yield` + `shutdown` rather than `await/2`: the collect loop is
        # already bounded by `timeout_ms + @kill_grace_ms`, so this outer bound
        # should never fire — and if it somehow does, the caller must get an
        # error, not an exit raised inside whatever asked for repo state.
        case Task.yield(task, timeout_ms + @kill_grace_ms + @await_margin_ms) ||
               Task.shutdown(task, :brutal_kill) do
          {:ok, result} -> result
          _timeout_or_exit -> {:error, :timeout}
        end
    end
  end

  defp spawn_and_await(git, repo_root, args, timeout_ms) do
    # A git call has no session, so its stderr file has no transcript to live
    # beside; tmp plus a best-effort delete is the whole lifecycle. Only the
    # windows shim writes it (spec B2) — `Exec` ignores the key, but it must
    # still be present, because `PortShim` refuses to start without one.
    stderr_path =
      Path.join(
        System.tmp_dir!(),
        "valea-git-#{System.unique_integer([:positive])}.stderr.log"
      )

    spec = %{
      cmd: git,
      args: ["-C", repo_root | args],
      env: git_env(),
      cd: repo_root,
      stderr_path: stderr_path,
      # git asks a question and we wait for the answer, so it has to see EOF:
      # with an open stdin, a git that decides to read it never exits and
      # every call becomes a timeout.
      stdin: :closed
    }

    try do
      case ProcessRuntime.start(spec, self()) do
        {:ok, handle} ->
          collect(handle, [], System.monotonic_time(:millisecond) + timeout_ms)

        {:error, reason} ->
          # A spawn that never happened cannot report an exit code, and the
          # contract admits no third error: callers treat it exactly as they
          # treat a git that never answered.
          Logger.warning("git spawn failed: #{inspect(reason)}")
          {:error, :timeout}
      end
    after
      File.rm(stderr_path)
    end
  end

  defp collect(handle, acc, deadline) do
    remaining = deadline - System.monotonic_time(:millisecond)

    if remaining <= 0 do
      kill(handle)
      {:error, :timeout}
    else
      receive do
        {:runtime_output, bin} ->
          collect(handle, [acc, bin], deadline)

        {:runtime_stderr, bin} ->
          collect(handle, [acc, bin], deadline)

        {:runtime_exit, code} ->
          {:ok, %{output: cap(IO.iodata_to_binary(acc)), exit: exit_code(code)}}
      after
        remaining ->
          kill(handle)
          {:error, :timeout}
      end
    end
  end

  # `stop/1` is asynchronous, so waiting for the exit it produces is what keeps
  # this module's promise: the OS process tree is confirmed gone before `run`
  # returns. If the grace runs out anyway, this task dies — taking the port
  # with it on windows, while the group kill already issued finishes on unix.
  defp kill(handle) do
    ProcessRuntime.stop(handle)

    receive do
      {:runtime_exit, _code} -> :ok
    after
      @kill_grace_ms -> :ok
    end
  end

  # `nil` is the runtime's "killed, code unknown" (a signal on unix); callers
  # only ever ask "was it zero?", so any non-answer is a failure.
  defp exit_code(code) when is_integer(code) and code >= 0, do: code
  defp exit_code(_unknown), do: 1

  defp cap(out) when byte_size(out) > @output_cap,
    do: binary_part(out, 0, @output_cap) <> "\n[output capped]"

  defp cap(out), do: out

  # `Valea.Agents.Env.minimal/0` returns a MAP, and the adapter merges it into
  # the environment the backend inherited — so this adds the no-prompt rule
  # without taking away the user's git configuration (HOME, and with it
  # ~/.gitconfig and their credential helper, is what makes a real push work).
  defp git_env do
    Valea.Agents.Env.minimal()
    |> Map.put("GIT_TERMINAL_PROMPT", "0")
  end
end
