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
      rpc_action(:runtime_check, :runtime_check)
    end

    resource Valea.Api.ICM do
      rpc_action(:icm_tree, :tree)
      rpc_action(:icm_page, :page)
      rpc_action(:save_icm_page, :save_page)
      rpc_action(:create_icm_page, :create_page)
      rpc_action(:create_icm_folder, :create_folder)
      rpc_action(:rename_icm_entry, :rename)
      rpc_action(:delete_icm_entry, :delete)
      rpc_action(:icm_entry_references, :references)
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
