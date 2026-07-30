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
      rpc_action(:workspace_switch_preflight, :workspace_switch_preflight)
      rpc_action(:runtime_check, :runtime_check)
    end

    resource Valea.Api.ICM do
      rpc_action(:icm_tree, :tree)
      rpc_action(:icm_list_dir, :list_dir)
      rpc_action(:icm_page, :page)
      rpc_action(:save_icm_page, :save_page)
      rpc_action(:create_icm_page, :create_page)
      rpc_action(:create_icm_page_from_template, :create_page_from_template)
      rpc_action(:create_icm_folder, :create_folder)
      rpc_action(:rename_icm_entry, :rename)
      rpc_action(:delete_icm_entry, :delete)
      rpc_action(:icm_entry_references, :references)
      rpc_action(:icm_search, :search)
      rpc_action(:icm_paths_exist, :paths_exist)
    end

    resource Valea.Api.Cockpit do
      rpc_action(:cockpit_today, :today)
    end

    resource Valea.Api.Agents do
      rpc_action(:create_agent_session, :create_session)
      rpc_action(:list_agent_sessions, :list_sessions)
      rpc_action(:list_recent_sessions_by_icm, :list_recent_sessions_by_icm)
      rpc_action(:list_sessions, :list_sessions_for)
      rpc_action(:resume_agent_session, :resume_agent_session)
      rpc_action(:harness_doctor, :harness_doctor)
      rpc_action(:harness_config, :harness_config)
      rpc_action(:set_harness_command, :set_harness_command)
      rpc_action(:archive_agent_session, :archive_agent_session)
      rpc_action(:delete_agent_session, :delete_agent_session)
    end

    resource Valea.Api.Audit do
      rpc_action(:list_audit_entries, :list_audit_entries)
    end

    resource Valea.Api.Mail do
      rpc_action(:mail_status, :mail_status)
      rpc_action(:setup_mail_account, :setup_mail_account)
      rpc_action(:get_mail_account_settings, :get_mail_account_settings)
      rpc_action(:mail_autoconfig, :mail_autoconfig)
      rpc_action(:remove_mail_account, :remove_mail_account)
      rpc_action(:purge_mail_account_files, :purge_mail_account_files)
      rpc_action(:readopt_mail_account, :readopt_mail_account)
      rpc_action(:discard_held_folder, :discard_held_folder)
      rpc_action(:set_mail_credential, :set_mail_credential)
      rpc_action(:start_mail_oauth, :start_mail_oauth)
      rpc_action(:mail_sync_now, :mail_sync_now)
      rpc_action(:mail_doctor, :mail_doctor)
      rpc_action(:create_mail_folders, :create_mail_folders)
      rpc_action(:list_mail_messages, :list_mail_messages)
      rpc_action(:search_mail, :search_mail)
      rpc_action(:list_mail_folders, :list_mail_folders)
      rpc_action(:get_mail_message, :get_mail_message)
      rpc_action(:get_mail_thread, :get_mail_thread)
      rpc_action(:list_trusted_mail_senders, :list_trusted_mail_senders)
      rpc_action(:set_mail_sender_trust, :set_mail_sender_trust)
      rpc_action(:mail_apply_ops, :mail_apply_ops)
      rpc_action(:push_draft_to_mailbox, :push_draft_to_mailbox)
      rpc_action(:list_mail_drafts, :list_mail_drafts)
      rpc_action(:get_mail_draft, :get_mail_draft)
      rpc_action(:write_mail_draft, :write_mail_draft)
      rpc_action(:revise_mail_draft, :revise_mail_draft)
      rpc_action(:get_mail_draft_review, :get_mail_draft_review)
      rpc_action(:send_draft, :send_draft)
      rpc_action(:resolve_send_review, :resolve_send_review)
      rpc_action(:retry_sent_copy, :retry_sent_copy)
    end

    resource Valea.Api.Calendar do
      rpc_action(:calendar_status, :calendar_status)
      rpc_action(:setup_calendar_source, :setup_calendar_source)
      rpc_action(:set_calendar_source_url, :set_calendar_source_url)
      rpc_action(:remove_calendar_source, :remove_calendar_source)
      rpc_action(:purge_calendar_source_files, :purge_calendar_source_files)
      rpc_action(:calendar_sync_now, :calendar_sync_now)
      rpc_action(:calendar_doctor, :calendar_doctor)
      rpc_action(:list_calendar_events, :list_calendar_events)
      rpc_action(:create_valea_event, :create_valea_event)
      rpc_action(:update_valea_event, :update_valea_event)
      rpc_action(:delete_valea_event, :delete_valea_event)
      rpc_action(:enable_calendar_feed, :enable_calendar_feed)
      rpc_action(:rotate_calendar_feed_token, :rotate_calendar_feed_token)
    end

    resource Valea.Api.Icms do
      rpc_action(:inspect_icm, :inspect_icm)
      rpc_action(:list_icms, :list_icms)
      rpc_action(:mount_icm, :mount_icm)
      rpc_action(:adopt_icm, :adopt_icm)
      rpc_action(:create_icm, :create_icm)
      rpc_action(:set_icm_enabled, :set_icm_enabled)
      rpc_action(:unmount_icm, :unmount_icm)
      rpc_action(:icm_doctor, :icm_doctor)
      rpc_action(:list_icm_mail_access, :list_icm_mail_access)
      rpc_action(:set_icm_mail_access, :set_icm_mail_access)
    end

    resource Valea.Api.Skills do
      rpc_action(:list_skills, :list_skills)
      rpc_action(:install_skill, :install_skill)
      rpc_action(:update_skill, :update_skill)
      rpc_action(:uninstall_skill, :uninstall_skill)
      rpc_action(:dismiss_skills_offer, :dismiss_skills_offer)
    end

    resource Valea.Api.Tasks do
      rpc_action(:list_tasks, :list_tasks)
      rpc_action(:create_task, :create_task)
      rpc_action(:mutate_task, :mutate_task)
      rpc_action(:archive_done, :archive_done)
    end

    resource Valea.Api.Schedules do
      rpc_action(:list_schedules, :list_schedules)
      rpc_action(:create_schedule, :create_schedule)
      rpc_action(:mutate_schedule, :mutate_schedule)
      rpc_action(:delete_schedule, :delete_schedule)
      rpc_action(:run_schedule_now, :run_schedule_now)
      rpc_action(:schedule_run_history, :schedule_run_history)
      rpc_action(:set_scheduler_paused, :set_scheduler_paused)
    end
  end

  resources do
    resource Valea.Api.Workspace
    resource Valea.Api.ICM
    resource Valea.Api.Cockpit
    resource Valea.Api.Agents
    resource Valea.Api.Audit
    resource Valea.Api.Mail
    resource Valea.Api.Calendar
    resource Valea.Api.Icms
    resource Valea.Api.Skills
    resource Valea.Api.Tasks
    resource Valea.Api.Schedules
  end
end
