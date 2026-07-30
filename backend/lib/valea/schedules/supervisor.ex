defmodule Valea.Schedules.Supervisor do
  @moduledoc """
  Everything the tasks+schedules runtime needs, as one `Valea.Workspace.
  Runtime` child (the mail/calendar supervisor shape), started with the
  workspace root and generation and dying with a workspace switch.

  Child order is load-bearing in both directions:

    * `Valea.Ledger.Writer` first — the serialization point for every
      Valea-side ledger mutation. The scheduler's daily auto-archive runs
      through it, so it must be up before the scheduler's first tick. It lives
      here rather than directly under the Runtime because schedules are its
      only in-runtime caller; the UI/RPC callers reach it by name either way.
    * `Valea.Schedules.RunRegistry` — where a command run registers under
      `{icm_id, schedule_id}`. This is what makes "one run at a time"
      *observable* rather than remembered (see `Valea.Schedules.Scheduler`'s
      "nothing that matters lives in this process").
    * `Valea.Schedules.RunSupervisor` — the DynamicSupervisor those command
      runs live under.
    * `Valea.Schedules.Scheduler` LAST, so on shutdown it is terminated FIRST:
      its `terminate/2` reads the Registry to mark still-running command runs
      `interrupted`, which only works while the Registry and the run processes
      are still alive.
  """
  use Supervisor

  def start_link(cfg), do: Supervisor.start_link(__MODULE__, cfg, name: __MODULE__)

  @impl true
  def init(cfg) do
    children = [
      Valea.Ledger.Writer,
      {Registry, keys: :unique, name: Valea.Schedules.RunRegistry},
      {DynamicSupervisor, name: Valea.Schedules.RunSupervisor, strategy: :one_for_one},
      {Valea.Schedules.Scheduler, cfg}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
