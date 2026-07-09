defmodule Valea.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      ValeaWeb.Telemetry,
      {Phoenix.PubSub, name: Valea.PubSub},
      # Workspace supervisor added in Task 7 (Repo starts under it when a
      # workspace opens — the app boots workspace-less by design).
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
