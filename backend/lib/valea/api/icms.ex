defmodule Valea.Api.Icms do
  @moduledoc """
  Data-layer-less Ash resource exposing `Valea.Mounts` (the `icms:`-based,
  by-reference-only mount API — mount/create/set_enabled/unmount/list) and
  `Valea.Mounts.Doctor` over RPC. This is the C9 (id/mount-key based)
  ICM-mount surface task 3.4 owns; it replaced `Valea.Api.Mounts` piece by
  piece from the frontend's perspective across Task 10.x — Phase 11 deleted
  `Valea.Api.Mounts` itself once nothing called it anymore.

  Every action here guards `Valea.Workspace.Manager.check_generation/1`
  FIRST (a stale `generation` short-circuits to `workspace_changed` before
  anything else runs, including `list_icms` — it is "mutating-adjacent":
  it reads LIVE filesystem/manifest state, not a cached value), then
  resolves `Valea.Workspace.Manager.current/0` for the open workspace's
  root, then calls the corresponding `Valea.Mounts` function against that
  root.

  `mount_icm`, `create_icm`, `set_icm_enabled`, and `unmount_icm` broadcast
  `{:mounts_changed}` on the `"mounts"` PubSub topic after their mutation
  succeeds — the exact same message `Valea.ICM.Watcher` broadcasts on
  filesystem discovery changes. `list_icms` and `icm_doctor` never
  broadcast — neither writes `config/workspace.yaml`.

  This resource does NOT regenerate `MOUNTS.md`/managed Claude settings
  after a mutation — that legacy workspace-metadata regeneration (the old
  `Valea.Api.Mounts`'s job) is superseded by Phase 10's harness/session-settings
  work (see the Phase 10 plan's "managed-settings mechanism" decision;
  `Valea.Agents.SessionSettings` is the live replacement) and was never
  carried forward here.

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

  ## `inspect_icm` (Task 10.1) — the onboarding preview primitive

  `inspect_icm(path)` is the odd one out in this resource: it takes NO
  `generation` and needs NO open workspace at all (unbound, same precedent
  as `Valea.Api.Workspace`'s `recent`/`get_workspace`/
  `workspace_switch_preflight`) — it exists so onboarding can ask "is this
  folder a healthy ICM?" BEFORE any workspace has been created or opened.
  It never mounts, never writes, and never raises an RPC-level error;
  every outcome — success or failure — comes back as `{:ok, %{...}}` with
  an `ok: boolean` discriminant, mirroring `icm_doctor`'s own
  boolean-result-not-RPC-error shape.

  Validation mirrors `Valea.Mounts`'s own `mount/2` pre-write gate
  (`validate_mountable/2`, which itself inlines the old
  `Valea.Mounts.External.check_boundaries/2`), but reimplements the
  workspace-INDEPENDENT sub-checks locally rather than calling it: that
  function takes a `workspace` argument to run its
  `:inside_workspace`/`:ancestor_of_workspace` boundary checks against, and
  there is no workspace here to pass — the same
  can't-call-a-private-function-from-another-module reason `Valea.Mounts`
  itself duplicates its `check_absolute?/1`/glob-safety checks rather than
  exposing them (see that module's own comments). Checked, in order:
  absolute-or-`~`-based (`:not_absolute` reason), resolves to
  `$HOME` or `/` (`:home_or_root` — the one boundary guardrail that IS
  workspace-independent and so DOES apply here), a Claude-Code
  permission-glob metacharacter in the resolved path (`:unsafe_path`), the
  resolved path is an existing directory, and finally
  `Valea.Mounts.Manifest.load/1`. Any loadable manifest (format 1 or 2,
  `Manifest.load/1` only ever rejects a missing/blank/non-UUID `id` or a
  missing/blank `name`) inspects `ok: true` — aligned with `mount/2`, which
  has always accepted format 1 (`Manifest.load/1` never gated on `format`;
  only this preview's OLD stricter check did, before Task 12/Spec D §D4).

  Every result also carries `"adoptable"` (Task 12, Spec D §D4): `true` iff
  the folder exists, passes the same boundary/glob checks above, and has NO
  `icm.yaml` at all (`Manifest.load/1` returns `{:error, :missing}`) —
  `false` for a healthy, an invalid, or a boundary-rejected folder alike. A
  folder reporting `adoptable: true` here is exactly the set `adopt_icm`
  below will accept (same `check_adoptable/2` gate in `Valea.Mounts`, only
  workspace-independent boundary checks re-run twice for two different
  reasons — this action has no workspace to compare against; `adopt_icm`
  re-validates against the LIVE workspace at mutation time rather than
  trusting a possibly-stale earlier `inspect_icm` read).
  """
  use Ash.Resource, domain: Valea.Api, extensions: [AshTypescript.Resource]

  typescript do
    type_name("Icms")
  end

  alias Valea.Api.Error
  alias Valea.Mounts
  alias Valea.Mounts.Doctor
  alias Valea.Mounts.Manifest
  alias Valea.Paths
  alias Valea.Workspace.Manager

  actions do
    # Onboarding's mount-preview primitive — see moduledoc. Deliberately
    # FIRST among the actions (no `generation` argument, unlike everything
    # below it) so its unbound nature reads immediately, not buried after
    # five generation-guarded ones.
    action :inspect_icm, :map do
      constraints fields: [
                    ok: [type: :boolean, allow_nil?: false],
                    name: [type: :string, allow_nil?: true],
                    description: [type: :string, allow_nil?: true],
                    reason: [type: :string, allow_nil?: true],
                    adoptable: [type: :boolean, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false

      run fn input, _ctx ->
        {:ok, do_inspect_icm(input.arguments.path)}
      end
    end

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

    # Adopt-a-folder (Task 12, Spec D §D4) — the consent-gated write that
    # follows an `inspect_icm` reporting `adoptable: true`. Mirrors
    # `:mount_icm`'s structure exactly; the only difference is the
    # `Valea.Mounts` function called and the extra `name` argument the mint
    # needs.
    action :adopt_icm, :map do
      constraints fields: [
                    mount_key: [type: :string, allow_nil?: false],
                    id: [type: :string, allow_nil?: false]
                  ]

      argument :path, :string, allow_nil?: false
      argument :name, :string, allow_nil?: false
      argument :generation, :integer, allow_nil?: false

      run fn input, _ctx ->
        %{path: path, name: name, generation: generation} = input.arguments

        with :ok <- Manager.check_generation(generation),
             {:ok, %{path: workspace}} <- Manager.current(),
             {:ok, %{mount_key: mount_key, id: id}} <- Mounts.adopt(workspace, path, name) do
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
  # Central error mapping for every action in this resource:
  # `Valea.Workspace.Manager`'s two generation-guard atoms, `Valea.Mounts`'s
  # own atoms, and the eight boundary/glob-safety reason atoms
  # `Valea.Mounts.mount/2`'s validation gate surfaces (formerly
  # `Valea.Mounts.External.validate_ref/2`'s vocabulary, inlined at Phase
  # 11). `{:mint_failed, reason}` is `adopt_icm`'s own (Task 12, Spec D
  # §D4) — the OS reason `Valea.Mounts.Manifest.write!/2` raised when
  # minting the adopted folder's `icm.yaml` (e.g. `:eacces`) is carried
  # through explicitly rather than falling to the generic `inspect/1`
  # catch-all, so the frontend gets a stable, greppable code.
  def error_for(:no_workspace), do: Error.new("workspace_not_open")
  def error_for({:invalid_manifest, _reason}), do: Error.new("invalid_manifest")
  def error_for({:mint_failed, reason}), do: Error.new("mint_failed: #{inspect(reason)}")
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

  # -- inspect_icm (Task 10.1) — see moduledoc -----------------------------

  defp do_inspect_icm(path) do
    if absolute_or_tilde?(path) do
      resolved = resolve_best_effort(Path.expand(path))
      check_inspect_boundaries(resolved)
    else
      inspect_failure("path must be an absolute path (or start with ~)")
    end
  end

  defp check_inspect_boundaries(resolved) do
    cond do
      home_or_root?(resolved) ->
        inspect_failure(
          "path points at the home directory or filesystem root — not a valid ICM location"
        )

      icm_glob_unsafe?(resolved) ->
        inspect_failure(
          "path contains characters unsafe for permission globs: *, ?, [, ], {, }, (, )"
        )

      not File.dir?(resolved) ->
        inspect_failure("no folder found at that path")

      true ->
        load_and_validate_manifest(resolved)
    end
  end

  defp load_and_validate_manifest(resolved) do
    case Manifest.load(resolved) do
      {:ok, manifest} ->
        %{
          "ok" => true,
          "name" => manifest.name,
          "description" => manifest.description,
          "reason" => nil,
          "adoptable" => false
        }

      {:error, :missing} ->
        %{
          "ok" => false,
          "name" => nil,
          "description" => nil,
          "reason" => "no icm.yaml found in that folder",
          "adoptable" => true
        }

      {:error, {:invalid, reason}} ->
        inspect_failure(reason)
    end
  end

  defp inspect_failure(reason) do
    %{
      "ok" => false,
      "name" => nil,
      "description" => nil,
      "reason" => reason,
      "adoptable" => false
    }
  end

  # Duplicated (rather than exposed as new public API) from `Valea.Mounts`
  # — see moduledoc's "inspect_icm" section for why: the live check needs a
  # `workspace` to compare against, and there is none here.
  defp absolute_or_tilde?("/" <> _rest), do: true
  defp absolute_or_tilde?("~"), do: true
  defp absolute_or_tilde?("~/" <> _rest), do: true
  defp absolute_or_tilde?(_relative), do: false

  defp home_or_root?(resolved),
    do: resolved == "/" or resolved == resolve_best_effort(System.user_home!())

  @glob_metacharacters ["*", "?", "[", "]", "{", "}", "(", ")"]

  defp icm_glob_unsafe?(resolved), do: String.contains?(resolved, @glob_metacharacters)

  # Self-base realpath resolution (`Paths.resolve_real(path, path)`) — an
  # inspected path is not naturally contained in any existing base, so
  # resolving it against itself makes containment trivially satisfied and
  # yields the fully symlink-walked physical path. Mirrors `Valea.Mounts`'s
  # identically-named private helper exactly.
  defp resolve_best_effort(path) do
    case Paths.resolve_real(path, path) do
      {:ok, resolved} -> resolved
      {:error, _reason} -> path
    end
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
