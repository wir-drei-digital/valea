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
      # Listed BEFORE the session supervisor a scheduled prompt fire needs, and
      # safe either way. The scheduler's first tick runs from `handle_continue`
      # (after every child's `init/1` has returned) and starts with a generation
      # check — a `Valea.Workspace.Manager` call that queues behind the
      # in-flight `open` and so cannot answer `:ok` until the whole Runtime,
      # session supervisor included, is up. If that check times out instead (it
      # is on a 500 ms leash), the tick is refused wholesale and no mount is
      # marked as having had its first pass, so the next tick redoes it. Nothing
      # launches in the window either way; the ordering is documentation, not the
      # mechanism.
      {Valea.Schedules.Supervisor, %{root: root, generation: gen}},
      # Inert until `{:workspace_opened, _, gen}` matches (mail's gating): a
      # Runtime that starts before the Manager finishes opening must not run a
      # pass — let alone a COMMIT — against a workspace that isn't current yet.
      {Valea.Git.Engine, %{root: root, generation: gen}},
      {DynamicSupervisor, name: Valea.Agents.SessionSupervisor, strategy: :one_for_one}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end
end
