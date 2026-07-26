defmodule Valea.Api.Skills do
  @moduledoc """
  ICM skills RPC (ICM skills design spec, §Backend): list / install /
  update / uninstall / dismiss-offer, per mounted ICM. Every action
  guards `Valea.Workspace.Manager.check_generation/1` FIRST. Trust model
  is the `set_harness_command` one — the settings click is the consent
  step; these actions are reachable only from the control-token-gated UI
  socket, and the agent tool surface carries no RPC access.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Skills")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Skills
  alias Valea.Workspace.Manager

  @row_fields [
    skill_id: [type: :string, allow_nil?: false],
    name: [type: :string, allow_nil?: false],
    description: [type: :string, allow_nil?: true],
    source_url: [type: :string, allow_nil?: true],
    license: [type: :string, allow_nil?: true],
    pinned: [type: :string, allow_nil?: true],
    state: [type: :string, allow_nil?: false],
    installed_version: [type: :string, allow_nil?: true]
  ]

  actions do
    action :list_skills, :map do
      constraints fields: [
                    skills: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [items: [fields: @row_fields]]
                    ],
                    dismissed: [type: {:array, :string}, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             {:ok, rows} <- Skills.list(ws, mount_key) do
          {:ok, %{skills: rows, dismissed: Mounts.skills_offers_dismissed(ws, mount_key)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :install_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.install(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :update_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :force, :boolean, allow_nil?: false, default: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, force: force, generation: generation} =
          input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.update(ws, mount_key, skill_id, force: force) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :uninstall_skill, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Skills.uninstall(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :dismiss_skills_offer, :map do
      constraints fields: [ok: [type: :boolean, allow_nil?: false]]
      argument :mount_key, :string, allow_nil?: false
      argument :skill_id, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, skill_id: skill_id, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: ws}} <- Manager.current(),
             :ok <- Mounts.dismiss_skills_offer(ws, mount_key, skill_id) do
          {:ok, %{ok: true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  # Central error mapping — the `Valea.Api.Icms.error_for/1` vocabulary.
  defp error_for(:no_workspace), do: Error.new("workspace_not_open")
  defp error_for(:mount_not_found), do: Error.new("icm_unavailable")
  defp error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  defp error_for(reason), do: Error.new(inspect(reason))
end
