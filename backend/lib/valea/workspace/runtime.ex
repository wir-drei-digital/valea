defmodule Valea.Workspace.Runtime do
  @moduledoc """
  Everything that lives and dies with an open workspace: file watcher,
  audit writer, agent sessions. Started by the Manager after a successful
  open+migration; fully stopped BEFORE a switch completes, so no process
  of the old workspace can touch the new one. Each start carries the
  workspace generation.
  """
  use Supervisor

  def start_link(cfg), do: Supervisor.start_link(__MODULE__, cfg, name: __MODULE__)

  @impl true
  def init(%{root: root, generation: gen}) do
    children = [
      {Valea.ICM.Watcher, root},
      {Valea.Audit, %{root: root, generation: gen}},
      {Valea.Mail.Supervisor, %{root: root, generation: gen}},
      {Valea.Calendar.Supervisor, %{root: root, generation: gen}},
      {DynamicSupervisor, name: Valea.Agents.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
