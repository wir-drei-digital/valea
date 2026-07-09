defmodule Valea.Workspace.Supervisor do
  @moduledoc """
  Owns everything whose lifetime is 'while a workspace is open': the Repo and
  (Task 9) the ICM watcher run under the DynamicSupervisor; the Manager
  decides when they start and stop.
  """
  use Supervisor

  def start_link(init_arg), do: Supervisor.start_link(__MODULE__, init_arg, name: __MODULE__)

  @impl true
  def init(_init_arg) do
    children = [
      {DynamicSupervisor, name: Valea.Workspace.DynamicSupervisor, strategy: :one_for_one},
      Valea.Workspace.Manager
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end
end
