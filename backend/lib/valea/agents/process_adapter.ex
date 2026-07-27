defmodule Valea.Agents.ProcessAdapter do
  @moduledoc """
  How Valea spawns an agent subprocess, per platform (windows-support spec
  B1). One adapter is selected ONCE at boot by
  `Valea.Agents.ProcessRuntime.select_adapter!/0`; everything else in the
  app talks to the facade, never to an adapter module.

  The owner-message contract is the same on every platform and is the reason
  this behaviour is narrow enough to have two implementations:

      {:runtime_output, binary}   # stdout — the NDJSON stream
      {:runtime_stderr, binary}   # stderr — NEVER fed to the JSON decoder
      {:runtime_exit, code | nil} # nil when the code is unknown (signal kill)

  Implementations:

    * `Valea.Agents.ProcessRuntime.Exec` — unix, via erlexec: separate
      stdout/stderr streams and a process-group kill.
    * `Valea.Agents.ProcessRuntime.PortShim` — windows, via an Erlang Port
      onto the `valea-spawn` shim, which supplies the two things a Port
      cannot: a separate stderr channel (a file) and a Job Object that kills
      the whole tree.

  ## The spec map

    * `cmd`, `args`, `cd` — what to run and where.
    * `env` — what Valea CONTRIBUTES to the child's environment. Both
      mechanisms (erlexec's `{:env, …}`, a Port's `{:env, …}`) MERGE into the
      environment the backend itself inherited; neither replaces it. So this
      map is not a sandbox — `Valea.Agents.Env.minimal/0` decides what Valea
      adds, and secrets stay out of it because they must never be ADDED, not
      because the child is otherwise sealed off.
    * `stderr_path` — the file the windows shim writes the child's stderr to
      (spec B2). `Exec` ignores it; `PortShim` refuses to start without it.
      Note that stderr on unix is a live stream and on windows a file tail
      delivered at exit — that coarseness is the documented platform
      difference, not a bug.
    * `stdin` — `:open` (default, what a session needs) or `:closed`.
      `:closed` means the child must see EOF on stdin immediately: a probe
      that runs `some-cli --version` and waits for it to exit hangs forever
      otherwise, because a program with an open stdin is entitled to read it.
      `Exec` honours this by omitting erlexec's `:stdin` option, so the child
      gets `/dev/null`. **`PortShim` CANNOT honour it**: the shim's contract
      makes stdin EOF the teardown signal (exit 120, Job closed), so closing
      it would kill the very process we are probing. On windows a
      `stdin: :closed` spawn therefore runs with an open-but-never-written
      stdin. That is acceptable only because no current probe's target reads
      stdin; a future probe that needs a real EOF needs a different
      mechanism (a shim flag), not a tweak here.
  """

  @doc "Spawn `spec` and relay its streams to `owner`. Returns an opaque handle."
  @callback start(map(), pid()) :: {:ok, map()} | {:error, String.t()}

  @doc "Write to the subprocess's stdin."
  @callback write(map(), iodata()) :: :ok

  @doc """
  Terminate the subprocess and everything it spawned. Asynchronous: the
  owner learns it is gone from `{:runtime_exit, code | nil}`.
  """
  @callback stop(map()) :: :ok
end
