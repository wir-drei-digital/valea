defmodule Valea.Api.Mounts do
  @moduledoc """
  Data-layer-less Ash resource exposing `Valea.Mounts` (list/enable/create)
  over RPC. Follows `Valea.Api.Queue`/`Valea.Api.Mail`'s conventions:

    * `constraints fields: [...]` typed actions for structured returns —
      `list_mounts`'s `mounts` field is a fully-typed array of
      `name`/`title`/`description`/`relRoot`/`enabled`/`degraded` (`degraded`
      nullable: `nil` for a healthy mount, a reason string otherwise). This
      is a NESTED array-item field, not a top-level one, so `enabled`
      staying an ordinary atom-keyed `:boolean` field is fine — the
      top-level generic-action boolean/falsy-map-field bug documented in
      `Valea.Api.Queue`'s moduledoc only reaches a field of the action's
      OWN top-level return map, not one nested inside an array item's
      `fields:`.
    * `set_mount_enabled`'s `saved` field, being top-level, DOES hit that
      bug — it uses the same STRING-key workaround (`%{"saved" => true}`)
      every other top-level boolean-returning mutation in this codebase
      uses.
    * Mutating actions (`set_mount_enabled`, `create_mount`) take a
      `generation` argument and guard with
      `Valea.Workspace.Manager.check_generation/1` before touching anything,
      same as `Valea.Api.Queue`/`Valea.Api.Mail`.

  `set_mount_enabled` and `create_mount` both regenerate `MOUNTS.md`
  (`Valea.Mounts.MountsMd.regenerate/1`) and broadcast `{:mounts_changed}`
  on the `"mounts"` PubSub topic afterwards — the EXACT same message
  `Valea.ICM.Watcher` broadcasts on filesystem discovery changes (Task
  A-T6), so a subscriber (the `mounts` topic push in
  `ValeaWeb.WorkspaceEventsChannel`) can't tell an RPC-driven change from a
  filesystem one. This is load-bearing for `set_mount_enabled` in
  particular: toggling `config/workspace.yaml`'s `mounts:` section touches
  a file OUTSIDE the `mounts/` tree the Watcher observes, so without this
  explicit broadcast, an enable/disable would never reach a live socket at
  all.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Mounts")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Mounts.MountsMd
  alias Valea.Workspace.Manager

  actions do
    action :list_mounts, :map do
      constraints fields: [
                    mounts: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            name: [type: :string, allow_nil?: false],
                            title: [type: :string, allow_nil?: false],
                            description: [type: :string, allow_nil?: false],
                            rel_root: [type: :string, allow_nil?: false],
                            enabled: [type: :boolean, allow_nil?: false],
                            degraded: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      run fn _input, _ctx ->
        case Mounts.list() do
          {:ok, mounts} -> {:ok, %{mounts: Enum.map(mounts, &to_rpc_mount/1)}}
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_mount_enabled, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :name, :string, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, enabled: enabled, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Mounts.set_enabled(name, enabled) do
          MountsMd.regenerate(root)
          broadcast_mounts_changed()
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_mount, :map do
      constraints fields: [rel_root: [type: :string, allow_nil?: false]]

      argument :name, :string, allow_nil?: false

      argument :description, :string,
        allow_nil?: false,
        constraints: [allow_empty?: true]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, description: description, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, mount} <- Mounts.create(root, name, description) do
          MountsMd.regenerate(root)
          broadcast_mounts_changed()
          {:ok, %{rel_root: mount.rel_root}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.Queue.error_for/1`. `:no_workspace` becomes the frontend's
  # `"workspace_not_open"` code; `:workspace_changed` (a stale generation)
  # and `Valea.Mounts`'s own atoms (`:invalid_mount_name`, `:already_exists`)
  # already stringify to the exact code the frontend expects.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  defp to_rpc_mount(mount) do
    %{
      name: mount.name,
      title: title_for(mount),
      description: description_for(mount),
      rel_root: mount.rel_root,
      enabled: mount.enabled,
      degraded: mount.degraded
    }
  end

  # A degraded mount may have `manifest: nil` — fall back to the directory
  # basename for `title` and to an empty string for `description` rather
  # than touching `mount.manifest`.
  defp title_for(%{manifest: %{name: name}}), do: name
  defp title_for(%{name: name}), do: name

  defp description_for(%{manifest: %{description: description}}), do: description
  defp description_for(_mount), do: ""

  # Mirrors `Valea.ICM.Watcher`'s own discovery-change broadcast EXACTLY
  # (same module, same topic, same message shape) — see moduledoc.
  defp broadcast_mounts_changed do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
  end
end
