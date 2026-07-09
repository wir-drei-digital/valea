defmodule Valea.Api do
  @moduledoc """
  The RPC-facing Ash domain. Groups the data-layer-less wrapper resources
  (Workspace / ICM / Cockpit) and exposes their generic actions to the
  TypeScript frontend via ash_typescript's RPC surface.
  """
  use Ash.Domain, extensions: [AshTypescript.Rpc]

  typescript_rpc do
    resource Valea.Api.Workspace do
      rpc_action(:get_workspace, :current)
      rpc_action(:create_workspace, :create_workspace)
      rpc_action(:open_workspace, :open_workspace)
      rpc_action(:close_workspace, :close_workspace)
      rpc_action(:recent_workspaces, :recent)
      rpc_action(:inspect_workspace, :inspect_workspace)
    end

    resource Valea.Api.ICM do
      rpc_action(:icm_tree, :tree)
      rpc_action(:icm_page, :page)
    end

    resource Valea.Api.Cockpit do
      rpc_action(:cockpit_today, :today)
    end
  end

  resources do
    resource Valea.Api.Workspace
    resource Valea.Api.ICM
    resource Valea.Api.Cockpit
  end
end
