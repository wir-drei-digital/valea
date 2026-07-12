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

    resource Valea.Api.Agents do
      rpc_action(:create_agent_session, :create_session)
      rpc_action(:list_agent_sessions, :list_sessions)
      rpc_action(:run_workflow, :run_workflow)
      rpc_action(:harness_doctor, :harness_doctor)
      rpc_action(:list_workflows, :list_workflows)
    end

    resource Valea.Api.Queue do
      rpc_action(:list_queue_items, :list_items)
      rpc_action(:get_queue_item, :get_item)
      rpc_action(:approve_queue_item, :approve_item)
      rpc_action(:reject_queue_item, :reject_item)
      rpc_action(:list_audit_entries, :list_audit_entries)
      rpc_action(:list_decided_queue_items, :list_decided_items)
    end

    resource Valea.Api.Mail do
      rpc_action(:mail_status, :mail_status)
      rpc_action(:setup_mail_account, :setup_mail_account)
      rpc_action(:set_mail_credential, :set_mail_credential)
      rpc_action(:mail_sync_now, :mail_sync_now)
      rpc_action(:mail_doctor, :mail_doctor)
      rpc_action(:create_mail_folders, :create_mail_folders)
      rpc_action(:list_mail_messages, :list_mail_messages)
      rpc_action(:get_mail_message, :get_mail_message)
      rpc_action(:mail_inbox, :mail_inbox)
      rpc_action(:retry_mailbox_ops, :retry_mailbox_ops)
    end

    resource Valea.Api.Mounts do
      rpc_action(:list_mounts, :list_mounts)
      rpc_action(:set_mount_enabled, :set_mount_enabled)
      rpc_action(:create_mount, :create_mount)
    end
  end

  resources do
    resource Valea.Api.Workspace
    resource Valea.Api.ICM
    resource Valea.Api.Cockpit
    resource Valea.Api.Agents
    resource Valea.Api.Queue
    resource Valea.Api.Mail
    resource Valea.Api.Mounts
  end
end
