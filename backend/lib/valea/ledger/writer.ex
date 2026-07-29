defmodule Valea.Ledger.Writer do
  @moduledoc """
  The serialization point for every Valea-side mutation of an ICM ledger
  (`tasks.json`, `schedules.json`, `.valea/task-archive.jsonl`) — the "one
  writer, a process, not a convention" the tasks+schedules spec asks for
  under §Write discipline.

  Mutations run *inside* this GenServer (`exec/1` hands it a zero-arity
  fun), so a UI click, an RPC, an archive sweep and the scheduler's daily
  auto-archive can never interleave their read-patch-write cycles with each
  other. The spec's minimum is one writer per ICM; this is one writer for
  the open workspace, which is stricter and simpler — ledger writes are
  human-paced, sub-millisecond, and never block on network I/O, so there is
  nothing to gain from finer granularity. Agents are outside this discipline
  by design (they use ordinary file tools); the optimistic-concurrency hash
  check in `Valea.Ledger.JsonFile` is what defends against them.

  Reads never come here — `Valea.Tasks.list/1` and friends read the file
  directly, so the cockpit and the UI cannot be blocked by a write.

  Lifecycle: a plain GenServer registered under its module name, started by
  `Valea.Workspace.Runtime` and therefore dying with a workspace switch like
  every other runtime child. Mutation APIs that route through here require
  an open workspace; without one the `GenServer.call/3` exits, loudly, which
  is the honest outcome for "asked Valea to write a file with no workspace
  open".

  Two rules for callers: never call `exec/1` from inside an `exec/1` fun
  (it would deadlock on itself), and keep the fun to ledger work — it holds
  up every other writer while it runs.
  """
  use GenServer

  # Ledger mutations are file-local: a read, a patch, a rename, plus (at
  # most) 3 conflict re-applies. 30 s is a "something is very wrong" bound,
  # not an expected duration.
  @call_timeout 30_000

  @doc """
  Starts the writer. Takes (and ignores) the Runtime's child argument so it
  can be listed as a bare module in the supervision tree.
  """
  def start_link(_arg \\ []), do: GenServer.start_link(__MODULE__, :ok, name: __MODULE__)

  @doc """
  Runs `fun` in the writer process and returns its value, serialized against
  every other `exec/1`.

  An exception, throw or exit inside `fun` is re-raised in the *caller* with
  its original stacktrace: a buggy mutation surfaces to whoever asked for it
  without taking down the writer (and with it every queued mutation).
  """
  @spec exec((-> term())) :: term()
  def exec(fun) when is_function(fun, 0) do
    case GenServer.call(__MODULE__, {:exec, fun}, @call_timeout) do
      {:ok, result} -> result
      {:raised, kind, reason, stacktrace} -> :erlang.raise(kind, reason, stacktrace)
    end
  end

  @impl true
  def init(:ok), do: {:ok, %{}}

  @impl true
  def handle_call({:exec, fun}, _from, state) do
    reply =
      try do
        {:ok, fun.()}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {:reply, reply, state}
  end
end
