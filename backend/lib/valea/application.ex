defmodule Valea.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ValeaWeb.Telemetry,
      {Phoenix.PubSub, name: Valea.PubSub},
      # App-level: agent sessions register by id here. The session PROCESSES
      # live under the workspace-scoped Valea.Agents.SessionSupervisor, but the
      # registry outlives workspace switches so lookups never race a restart.
      {Registry, keys: :unique, name: Valea.Agents.SessionRegistry},
      # Repo starts under here when a workspace opens — the app boots
      # workspace-less by design; there is no database until then.
      Valea.Workspace.Supervisor,
      ValeaWeb.Endpoint
    ]

    Supervisor.start_link(children, strategy: :one_for_one, name: Valea.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    ValeaWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
