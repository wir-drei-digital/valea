defmodule Valea.Api.Icms do
  @moduledoc """
  Data-layer-less Ash resource exposing `Valea.Mounts` (the `icms:`-based,
  by-reference-only mount API — mount/create/set_enabled/unmount/list) and
  `Valea.Mounts.Doctor` over RPC. This is the C9 (id/mount-key based)
  ICM-mount surface task 3.4 owns, replacing `Valea.Api.Mounts` piece by
  piece from the frontend's perspective — `Valea.Api.Mounts` itself stays
  registered/compiling until Phase 11 deletes it, this resource does not
  remove or touch it.

  Every action here guards `Valea.Workspace.Manager.check_generation/1`
  FIRST (a stale `generation` short-circuits to `workspace_changed` before
  anything else runs, including `list_icms` — it is "mutating-adjacent" the
  same way `Valea.Api.Mounts`'s `mounts_doctor` is: it reads LIVE
  filesystem/manifest state, not a cached value), then resolves
  `Valea.Workspace.Manager.current/0` for the open workspace's root, then
  calls the corresponding `Valea.Mounts` function against that root.

  `mount_icm`, `create_icm`, `set_icm_enabled`, and `unmount_icm` broadcast
  `{:mounts_changed}` on the `"mounts"` PubSub topic after their mutation
  succeeds — the exact same message `Valea.ICM.Watcher` broadcasts on
  filesystem discovery changes (mirrors `Valea.Api.Mounts`'s own broadcast;
  see that module's moduledoc for why this is deliberate, not vestigial).
  `list_icms` and `icm_doctor` never broadcast — neither writes
  `config/workspace.yaml`.

  Unlike `Valea.Api.Mounts`, this resource does NOT call
  `Valea.Mounts.MountsMd.regenerate/1` / `Valea.Agents.ClaudeSettings.write!/1`
  after a mutation — that legacy workspace-metadata regeneration is being
  superseded by Phase 10's harness/session-settings work (see the Phase 10
  plan's "managed-settings mechanism" decision), not carried forward here.

  `list_icms` returns one entry per `Valea.Mounts.mount()` — `mount_key`
  (the `icms:` config key, `mount.name` on the underlying struct), `id`
  (the manifest's stable UUID, `nil` for a degraded mount with no loadable
  manifest), `name` (the ICM's own display name — `manifest.name`, falling
  back to `mount_key` when degraded), `description` (`manifest.description`,
  `""` when degraded), `root` (the resolved absolute path, always present),
  `enabled`, and `degraded` (a reason string, or `nil` when healthy) — same
  degrade-tolerant fallback `Valea.Api.Mounts.to_rpc_mount/1` uses for
  `title`/`description`.

  `mount_icm`/`create_icm` return `%{mount_key, id}` (mirrors
  `Valea.Mounts.mount/2`/`create/3`'s own success shape). `set_icm_enabled`/
  `unmount_icm` return a top-level boolean (`saved`/`unmounted`) under a
  STRING key — the same ash_typescript 0.17.3 falsy-map-field workaround
  `Valea.Api.Mounts`/`Valea.Api.Queue`/`Valea.Api.Mail` all use for a
  top-level boolean-returning generic action.

  `icm_doctor` wraps `Valea.Mounts.Doctor.run/2` (Phase 8's real per-mount
  entry point) — `path_resolves`, `manifest_format2`, `unique_id`,
  `related_icms`, `secrets_hygiene`, `watcher_live`, scoped to the one
  requested `mount_key`. `:mount_not_found` (no `icms:` entry at all for
  that key) maps to the same error vocabulary every other mutating action
  here uses.
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Icms")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Mounts.Doctor
  alias Valea.Workspace.Manager

  actions do
    action :list_icms, :map do
      constraints fields: [
                    icms: [
                      type: {:array, :map},
                      allow_nil?: false,
                      constraints: [
                        items: [
                          fields: [
                            mount_key: [type: :string, allow_nil?: false],
                            id: [type: :string, allow_nil?: true],
                            name: [type: :string, allow_nil?: false],
                            description: [type: :string, allow_nil?: false],
                            root: [type: :string, allow_nil?: false],
                            enabled: [type: :boolean, allow_nil?: false],
                            degraded: [type: :string, allow_nil?: true]
                          ]
                        ]
                      ]
                    ]
                  ]

      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        with :ok <- Manager.check_generation(input.arguments.generation),
             {:ok, %{path: root}} <- Manager.current() do
          {:ok, %{icms: root |> Mounts.list() |> Enum.map(&to_rpc_icm/1)}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :mount_icm, :map do
      constraints fields: [
                    mount_key: [type: :string, allow_nil?: false],
                    id: [type: :string, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{path: path, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, %{mount_key: mount_key, id: id}} <- Mounts.mount(root, path) do
          broadcast_mounts_changed()
          {:ok, %{mount_key: mount_key, id: id}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :create_icm, :map do
      constraints fields: [
                    mount_key: [type: :string, allow_nil?: false],
                    id: [type: :string, allow_nil?: false]
                  ]

      argument :name, :string, allow_nil?: false
      argument :path, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{name: name, path: path, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, %{mount_key: mount_key, id: id}} <- Mounts.create(root, name, path) do
          broadcast_mounts_changed()
          {:ok, %{mount_key: mount_key, id: id}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :set_icm_enabled, :map do
      constraints fields: [saved: [type: :boolean, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :enabled, :boolean, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, enabled: enabled, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             :ok <- Mounts.set_enabled(root, mount_key, enabled) do
          broadcast_mounts_changed()
          {:ok, %{"saved" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    action :unmount_icm, :map do
      constraints fields: [unmounted: [type: :boolean, allow_nil?: false]]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, _path} <- Mounts.unmount(root, mount_key) do
          broadcast_mounts_changed()
          {:ok, %{"unmounted" => true}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end

    # Read-only probe (like `Valea.Api.Mounts.mounts_doctor`) — takes/guards
    # `generation` even though it never writes config, since it inspects LIVE
    # state (the watcher's current root set, the filesystem under the
    # requested mount's resolved root).
    action :icm_doctor, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    checks: [type: {:array, :map}, allow_nil?: false]
                  ]

      argument :mount_key, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{mount_key: mount_key, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: root}} <- Manager.current(),
             {:ok, %{checks: checks, ok: ok}} <- Doctor.run(root, mount_key) do
          {:ok, %{"ok" => ok, "checks" => checks}}
        else
          {:error, reason} -> {:error, error_for(reason)}
        end
      end
    end
  end

  @doc false
  # Central error mapping for every action in this resource — mirrors
  # `Valea.Api.Mounts.error_for/1` exactly (same dependency, same reason
  # vocabulary: `Valea.Workspace.Manager`'s two generation-guard atoms,
  # `Valea.Mounts`'s own atoms, and `Valea.Mounts.External.validate_ref/2`'s
  # eight reason atoms surfaced through `Valea.Mounts.mount/2`'s validation
  # gate).
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for({:invalid_manifest, _reason}), do: Error.new("invalid_manifest")
  def error_for(reason) when is_atom(reason), do: Error.new(to_string(reason))
  def error_for(reason), do: Error.new(inspect(reason))

  defp to_rpc_icm(mount) do
    %{
      mount_key: mount.name,
      id: id_for(mount),
      name: name_for(mount),
      description: description_for(mount),
      root: mount.root,
      enabled: mount.enabled,
      degraded: mount.degraded
    }
  end

  defp id_for(%{manifest: %{id: id}}), do: id
  defp id_for(_mount), do: nil

  # A degraded mount may have `manifest: nil` — fall back to the mount key
  # (the one name always present) rather than touching `mount.manifest`.
  defp name_for(%{manifest: %{name: name}}), do: name
  defp name_for(%{name: name}), do: name

  defp description_for(%{manifest: %{description: description}}), do: description
  defp description_for(_mount), do: ""

  # Mirrors `Valea.ICM.Watcher`'s own discovery-change broadcast EXACTLY
  # (same module, same topic, same message shape) — see moduledoc.
  defp broadcast_mounts_changed do
    Phoenix.PubSub.broadcast(Valea.PubSub, "mounts", {:mounts_changed})
  end
end
