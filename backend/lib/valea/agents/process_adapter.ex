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

  `start/2`'s spec map is `%{cmd, args, env, cd}` plus `stderr_path` — the
  file the windows shim writes the child's stderr to (spec B2). `Exec`
  ignores that key; `PortShim` refuses to start without it. A `stderr` on
  unix is a stream, on windows a file tail delivered at exit — that
  coarseness is the documented platform difference, not a bug.
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
